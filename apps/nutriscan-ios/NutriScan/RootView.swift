import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct RootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var draft = AnalysisDraft()
    @State private var preferences = UserPreferenceSelection()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(selectedTab: $selectedTab)
            }
            .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.systemImage) }
            .tag(AppTab.home)

            NavigationStack {
                ScanView(
                    draft: $draft,
                    selectedTab: $selectedTab,
                    preferences: preferences
                )
            }
            .tabItem { Label(AppTab.scan.title, systemImage: AppTab.scan.systemImage) }
            .tag(AppTab.scan)

            NavigationStack {
                ResultsView(draft: draft)
            }
            .tabItem { Label(AppTab.results.title, systemImage: AppTab.results.systemImage) }
            .tag(AppTab.results)

            NavigationStack {
                PreferencesView(preferences: $preferences)
            }
            .tabItem { Label(AppTab.preferences.title, systemImage: AppTab.preferences.systemImage) }
            .tag(AppTab.preferences)

            NavigationStack {
                HistoryView()
            }
            .tabItem { Label(AppTab.history.title, systemImage: AppTab.history.systemImage) }
            .tag(AppTab.history)
        }
    }
}

private struct HomeView: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        List {
            Section {
                Button {
                    selectedTab = .scan
                } label: {
                    Label("Start scan", systemImage: "camera")
                }
                Button {
                    selectedTab = .history
                } label: {
                    Label("Open history", systemImage: "clock")
                }
            }

            Section("Safety") {
                Text("NutriScan provides general nutrition and ingredient information and is not medical advice.")
                Text("For allergy decisions, verify the physical label before using the product.")
            }
        }
        .navigationTitle("NutriScan")
    }
}

private struct ScanView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var draft: AnalysisDraft
    @Binding var selectedTab: AppTab
    let preferences: UserPreferenceSelection
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var saveMessage: String?

    var body: some View {
        Form {
            Section("Capture") {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Choose label photo", systemImage: "photo")
                }
                Button {
                    isShowingCamera = true
                } label: {
                    Label("Take label photo", systemImage: "camera")
                }
                Text("Photos and OCR drafts stay on this iPhone unless you share them from History.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("OCR review") {
                TextEditor(text: $draft.ocrText)
                    .frame(minHeight: 220)
                    .accessibilityLabel("OCR text")
                Text("Local OCR capture will populate this text before analysis.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let diagnostics = draft.ocrDiagnostics {
                Section("OCR diagnostics") {
                    ForEach(diagnostics.displayRows, id: \.0) { row in
                        LabeledContent(row.0, value: row.1)
                    }
                }
            }

            Section {
                Button {
                    saveCaptureDraft()
                } label: {
                    Label(captureDraftActionTitle, systemImage: captureDraftActionIcon)
                }
                .disabled(!draft.hasCollectableContent)

                if draft.savedCaptureDraftID != nil {
                    Label("Draft saved to History", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Button {
                    Task {
                        await analyzeDraft()
                    }
                } label: {
                    Label("Analyze text", systemImage: "text.magnifyingglass")
                }
                .disabled(draft.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let saveMessage {
                Section("Saved") {
                    Label(saveMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button {
                        selectedTab = .history
                    } label: {
                        Label("Open history", systemImage: "clock")
                    }
                }
            }

            if draft.isLoading {
                Section {
                    ProgressView("Reading label text")
                }
            }

            if let errorMessage = draft.errorMessage {
                Section("Issue") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                    if !draft.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            Task {
                                await analyzeDraft()
                            }
                        } label: {
                            Label("Retry analysis", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .navigationTitle("Scan")
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                await loadPhoto(item)
            }
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraCaptureView { image in
                isShowingCamera = false
                Task {
                    await recognize(
                        image: image,
                        imageData: image.jpegData(compressionQuality: 0.9),
                        imageReference: "camera:\(Date.now.timeIntervalSince1970)"
                    )
                }
            } onCancel: {
                isShowingCamera = false
            }
        }
    }

    private var captureDraftActionTitle: String {
        draft.savedCaptureDraftID == nil ? "Save capture draft" : "Update capture draft"
    }

    private var captureDraftActionIcon: String {
        draft.savedCaptureDraftID == nil ? "tray.and.arrow.down" : "arrow.triangle.2.circlepath"
    }

    private func saveCaptureDraft() {
        do {
            if let scan = try existingCaptureDraft() {
                scan.ocrText = draft.ocrText
                scan.imageReference = draft.imageReference
                scan.imageFileName = try storeDraftImageIfAvailable(existingFileName: scan.imageFileName)
                scan.summary = "Saved OCR/photo draft for fixture review. Analysis has not been run."
                saveMessage = "Capture draft updated locally."
            } else {
                let scanID = UUID()
                let imageFileName = try storeDraftImageIfAvailable(existingFileName: nil)
                let scan = SavedScan(
                    id: scanID,
                    title: ScanTitleFormatter.title(prefix: "Capture"),
                    ocrText: draft.ocrText,
                    imageReference: draft.imageReference,
                    imageFileName: imageFileName,
                    summary: "Saved OCR/photo draft for fixture review. Analysis has not been run."
                )
                modelContext.insert(scan)
                draft.savedCaptureDraftID = scanID
                saveMessage = "Capture draft saved locally."
            }
        } catch {
            draft.errorMessage = "The capture draft could not be saved: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func analyzeDraft() async {
        draft.isLoading = true
        draft.errorMessage = nil
        do {
            let analysis = try await NutriScanAPI.analyze(
                ocrText: draft.ocrText,
                preferences: preferences
            )
            draft.analysis = analysis
            draft.summary = analysis.summary
            selectedTab = .results
        } catch {
            draft.errorMessage = error.localizedDescription
        }
        draft.isLoading = false
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        draft.isLoading = true
        draft.errorMessage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                draft.errorMessage = "The selected photo could not be loaded."
                draft.isLoading = false
                return
            }
            await recognize(
                image: image,
                imageData: image.jpegData(compressionQuality: 0.9),
                imageReference: item.itemIdentifier
            )
        } catch {
            draft.errorMessage = error.localizedDescription
            draft.isLoading = false
        }
    }

    @MainActor
    private func recognize(image: UIImage, imageData: Data?, imageReference: String?) async {
        draft.isLoading = true
        draft.errorMessage = nil
        saveMessage = nil
        draft.imageData = imageData
        draft.imageReference = imageReference
        draft.savedCaptureDraftID = nil
        draft.ocrDiagnostics = nil
        do {
            let result = try await OCRScanner.scan(image: image)
            draft.ocrText = result.text
            draft.ocrDiagnostics = result.diagnostics
        } catch {
            draft.errorMessage = error.localizedDescription
        }
        draft.isLoading = false
    }

    private func existingCaptureDraft() throws -> SavedScan? {
        guard let savedCaptureDraftID = draft.savedCaptureDraftID else { return nil }
        var descriptor = FetchDescriptor<SavedScan>(
            predicate: #Predicate { scan in
                scan.id == savedCaptureDraftID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storeDraftImageIfAvailable(existingFileName: String?) throws -> String? {
        if let existingFileName {
            return existingFileName
        }
        guard let imageData = draft.imageData else { return nil }
        return try LabelImageStore.saveJPEGData(imageData)
    }
}

private struct ResultsView: View {
    @Environment(\.modelContext) private var modelContext
    let draft: AnalysisDraft
    @State private var saveMessage: String?

    var body: some View {
        List {
            Section("Summary") {
                Text(draft.summary)
            }

            Section("Nutrition") {
                if let nutrition = draft.analysis?.nutrition {
                    nutritionRow("Serving size", nutrition.servingSizeText)
                    nutritionRow("Calories", nutrition.calories)
                    nutritionRow("Added sugar", nutrition.addedSugarG, unit: "g")
                    nutritionRow("Sodium", nutrition.sodiumMg, unit: "mg")
                    nutritionRow("Protein", nutrition.proteinG, unit: "g")
                } else {
                    Text("Pending analysis")
                }
            }

            Section("Ingredients and warnings") {
                if let ingredientAnalysis = draft.analysis?.ingredientAnalysis {
                    if !ingredientAnalysis.containsAllergens.isEmpty {
                        LabeledContent("Contains", value: ingredientAnalysis.containsAllergens.joined(separator: ", "))
                    }
                    if !ingredientAnalysis.mayContainAllergens.isEmpty {
                        LabeledContent("May contain", value: ingredientAnalysis.mayContainAllergens.joined(separator: ", "))
                    }
                    ForEach(ingredientAnalysis.ingredientConcerns, id: \.ingredient) { concern in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(concern.ingredient, systemImage: "exclamationmark.circle")
                                .font(.headline)
                            Text(concern.reason)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(ingredientAnalysis.flags, id: \.self) { flag in
                        Label(flag, systemImage: "exclamationmark.triangle")
                    }
                } else {
                    Text("Detected allergens and facility warnings will appear here after API integration.")
                }
                Text("No absolute safety claims are made from scanned text.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let confidence = draft.analysis?.confidence {
                Section("Confidence") {
                    if let region = confidence["detected_region"]?.displayText {
                        LabeledContent("Detected region", value: region.uppercased())
                    }
                    if let parser = confidence["parser"]?.displayText {
                        LabeledContent("Parser", value: parser)
                    }
                    if let notes = confidence["notes"]?.displayText, !notes.isEmpty {
                        LabeledContent("Notes", value: notes)
                    }
                }
            }

            Section {
                Button {
                    saveScan()
                } label: {
                    Label("Save scan", systemImage: "tray.and.arrow.down")
                }
                .disabled(draft.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let saveMessage {
                    Text(saveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Results")
    }

    private func saveScan() {
        do {
            let imageFileName = try storeDraftImageIfAvailable()
            let scan = SavedScan(
                title: ScanTitleFormatter.title(prefix: "Scan"),
                ocrText: draft.ocrText,
                imageReference: draft.imageReference,
                imageFileName: imageFileName,
                summary: draft.summary
            )
            modelContext.insert(scan)
            saveMessage = "Scan saved locally."
        } catch {
            saveMessage = "The image could not be saved, but OCR text is still available in this scan."
            let scan = SavedScan(
                title: ScanTitleFormatter.title(prefix: "Scan"),
                ocrText: draft.ocrText,
                imageReference: draft.imageReference,
                summary: draft.summary
            )
            modelContext.insert(scan)
        }
    }

    private func storeDraftImageIfAvailable() throws -> String? {
        guard let imageData = draft.imageData else { return nil }
        return try LabelImageStore.saveJPEGData(imageData)
    }

    @ViewBuilder
    private func nutritionRow(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title, value: value)
        }
    }

    @ViewBuilder
    private func nutritionRow(_ title: String, _ value: Double?, unit: String = "") -> some View {
        if let value {
            LabeledContent(title, value: formatted(value, unit: unit))
        }
    }

    private func formatted(_ value: Double, unit: String) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}

private struct PreferencesView: View {
    @Binding var preferences: UserPreferenceSelection
    @State private var avoidIngredient = ""
    @State private var lowSugar = false

    var body: some View {
        Form {
            Section("Allergens to flag") {
                preferenceToggle("Milk", value: "milk", values: $preferences.allergens)
                preferenceToggle("Peanuts", value: "peanuts", values: $preferences.allergens)
                preferenceToggle("Gluten", value: "gluten", values: $preferences.allergens)
            }

            Section("Nutrition goals") {
                Toggle("Lower added sugar", isOn: $lowSugar)
                    .onChange(of: lowSugar) { _, enabled in
                        preferences.nutritionGoals = enabled ? NutritionGoals(maxAddedSugarG: 5, maxSodiumMg: nil) : nil
                    }
            }

            Section("Avoid ingredients") {
                HStack {
                    TextField("Ingredient", text: $avoidIngredient)
                        .textInputAutocapitalization(.never)
                    Button {
                        addAvoidIngredient()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(avoidIngredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ForEach(preferences.avoidIngredients, id: \.self) { ingredient in
                    Text(ingredient)
                }
                .onDelete { offsets in
                    preferences.avoidIngredients.remove(atOffsets: offsets)
                }
            }

            Section("Dietary preferences") {
                preferenceToggle("Vegetarian", value: "vegetarian", values: $preferences.dietaryPreferences)
                preferenceToggle("Vegan", value: "vegan", values: $preferences.dietaryPreferences)
                preferenceToggle("Gluten-free", value: "gluten-free", values: $preferences.dietaryPreferences)
            }

            Section("Safety") {
                Text("NutriScan provides general nutrition and ingredient information and is not medical advice.")
                Text("For high-risk allergy scenarios, verify the physical label before using the product.")
            }
        }
        .navigationTitle("Preferences")
    }

    private func addAvoidIngredient() {
        let normalized = avoidIngredient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !preferences.avoidIngredients.contains(normalized) else { return }
        preferences.avoidIngredients.append(normalized)
        avoidIngredient = ""
    }

    private func preferenceToggle(
        _ title: String,
        value: String,
        values: Binding<[String]>
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { values.wrappedValue.contains(value) },
                set: { enabled in
                    if enabled {
                        values.wrappedValue.append(value)
                    } else {
                        values.wrappedValue.removeAll { $0 == value }
                    }
                }
            )
        )
    }
}

private struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedScan.createdAt, order: .reverse) private var scans: [SavedScan]

    var body: some View {
        List {
            if scans.isEmpty {
                ContentUnavailableView(
                    "No saved scans",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Saved label analyses will appear here.")
                )
            } else {
                ForEach(scans) { scan in
                    NavigationLink {
                        SavedScanDetailView(scan: scan)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scan.title)
                                .font(.headline)
                            Text(scan.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteScans)
            }
        }
        .navigationTitle("History")
        .toolbar {
            EditButton()
        }
    }

    private func deleteScans(at offsets: IndexSet) {
        for offset in offsets {
            modelContext.delete(scans[offset])
        }
    }
}

private struct SavedScanDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let scan: SavedScan
    @State private var ocrExportURL: URL?
    @State private var savedImage: UIImage?
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        List {
            Section("Summary") {
                Text(scan.summary)
            }

            if let savedImage {
                Section("Label photo") {
                    Image(uiImage: savedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else if scan.imageFileName != nil {
                Section("Label photo") {
                    ContentUnavailableView(
                        "Photo unavailable",
                        systemImage: "photo",
                        description: Text("The saved image file could not be loaded.")
                    )
                }
            }

            Section("OCR text") {
                Text(scan.ocrText)
                    .textSelection(.enabled)
            }

            Section("Export") {
                if let ocrExportURL {
                    ShareLink(item: ocrExportURL) {
                        Label("Share OCR text", systemImage: "doc.text")
                    }
                }

                if let imageURL = scan.storedImageURL {
                    ShareLink(item: imageURL) {
                        Label("Share label photo", systemImage: "photo")
                    }
                }

                Text("Use these exports to place photos in tests/fixtures/label-images/inbox and OCR snapshots under backend/nutriscan-api/tests/fixtures.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let imageReference = scan.imageReference {
                Section("Image reference") {
                    Text(imageReference)
                }
            }

            Section {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Label("Delete scan", systemImage: "trash")
                }
            }
        }
        .navigationTitle(scan.title)
        .confirmationDialog(
            "Delete this saved scan?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete scan", role: .destructive) {
                deleteScan()
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            ocrExportURL = try? LabelExportStore.writeOCRText(for: scan)
            savedImage = loadSavedImage()
        }
    }

    private func loadSavedImage() -> UIImage? {
        guard let imageURL = scan.storedImageURL,
              let data = try? Data(contentsOf: imageURL)
        else {
            return nil
        }
        return UIImage(data: data)
    }

    private func deleteScan() {
        modelContext.delete(scan)
        dismiss()
    }
}

private extension AnalysisDraft {
    var hasCollectableContent: Bool {
        imageData != nil || !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview {
    RootView()
        .modelContainer(for: SavedScan.self, inMemory: true)
}
