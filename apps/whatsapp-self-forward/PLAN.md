# iOS Shortcut: WhatsApp Self-Forward

## Overview
Create an iOS Shortcut that enables one-tap forwarding of content (text, links, images) to your own WhatsApp account for quick note-taking and content saving.

---

## Use Cases
- Save interesting articles/links to yourself
- Quick note-taking via share sheet
- Forward content from any app to WhatsApp for later reference
- Create a "Send to Self" button on home screen

---

## Technical Approach

### Option 1: WhatsApp URL Scheme (Recommended)
WhatsApp supports deep linking via URL schemes:

```
whatsapp://send?phone=YOURNUMBER&text=CONTENT
```

**Pros:**
- Direct integration with WhatsApp
- Works offline (opens WhatsApp directly)
- Fast execution

**Cons:**
- Requires one confirmation tap in WhatsApp to send
- Limited to text content via URL scheme

### Option 2: WhatsApp Click-to-Chat API
```
https://wa.me/YOURNUMBER?text=CONTENT
```

**Pros:**
- Works across platforms
- No app-specific URL scheme needed

**Cons:**
- Opens browser first, then redirects
- Slower than direct URL scheme

### Option 3: WhatsApp Share Extension
Use iOS share sheet to pass content directly to WhatsApp.

**Pros:**
- Supports images, videos, files
- Native iOS experience

**Cons:**
- Requires manual contact selection each time

---

## Recommended Implementation

### Shortcut Structure

```
┌─────────────────────────────────────────┐
│  TRIGGER OPTIONS                        │
│  • Share Sheet (from any app)           │
│  • Home Screen Widget                   │
│  • Siri Voice Command                   │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│  INPUT HANDLING                         │
│  • Accept: Text, URLs, Images           │
│  • If no input: Prompt for text         │
│  • Get Clipboard (optional fallback)    │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│  CONTENT PROCESSING                     │
│  • URL encode text content              │
│  • Format with timestamp (optional)     │
│  • Add source app name (optional)       │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│  WHATSAPP INTEGRATION                   │
│  • Text: Use URL scheme                 │
│  • Media: Use Share Sheet action        │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│  CONFIRMATION                           │
│  • Haptic feedback                      │
│  • Brief notification (optional)        │
└─────────────────────────────────────────┘
```

---

## Step-by-Step Implementation

### Step 1: Create New Shortcut
1. Open **Shortcuts** app on iPhone
2. Tap **+** to create new shortcut
3. Name it: "Send to WhatsApp Self"

### Step 2: Configure Input
Add these actions in order:

```
1. [Receive] → Accept: Text, URLs, Rich Text, Images
   - Show in Share Sheet: ON

2. [If] → If "Shortcut Input" has any value
   - Then: Continue
   - Otherwise: Ask for Input
```

### Step 3: Set Your Phone Number
```
3. [Text] → Your phone number with country code
   Example: 14155551234 (no + or spaces)
   Save to variable: "MyNumber"
```

### Step 4: Process Text Content
```
4. [If] → If "Shortcut Input" is Text/URL

   5. [Text] → whatsapp://send?phone=[MyNumber]&text=[Shortcut Input]

   6. [URL Encode] → Encode the text portion

   7. [Open URL] → Open the constructed URL
```

### Step 5: Handle Image/Media Content
```
8. [Otherwise] → For non-text content

   9. [Share] → Share "Shortcut Input" with WhatsApp

   (This opens WhatsApp's share extension)
```

### Step 6: Add Feedback
```
10. [Play Sound] → Optional success sound

11. [Show Notification] → "Sent to WhatsApp" (optional)
```

---

## Quick Setup Version (Minimal)

For a simpler version that just handles text:

```
Action 1: Receive [Text, URLs] input from Share Sheet
Action 2: Text → "whatsapp://send?phone=YOUR_NUMBER&text="
Action 3: Combine Text → [Action 2] + [Shortcut Input]
Action 4: URL Encode → [Action 3]
Action 5: Open URL → [Action 4]
```

---

## Configuration Options

### Your Phone Number
Replace `YOUR_NUMBER` with your phone number in international format:
- US: `14155551234`
- UK: `447911123456`
- India: `919876543210`

**Important:** No `+`, no spaces, no dashes.

### Optional Enhancements

1. **Add Timestamp**
   ```
   [Current Date] → Format: "yyyy-MM-dd HH:mm"
   Prepend to message: "[timestamp] Your content"
   ```

2. **Add Source Context**
   ```
   Include app name that shared the content
   Format: "From [App]: Content"
   ```

3. **Quick Notes Mode**
   ```
   Add a separate shortcut that:
   - Prompts for text input
   - Sends directly to WhatsApp
   - No share sheet needed
   ```

---

## Trigger Options

### 1. Share Sheet
- Appears when you tap "Share" in any app
- Most versatile option

### 2. Home Screen Widget
- Add shortcut to home screen
- Tap to send clipboard or prompt for input

### 3. Back Tap (iPhone 8+)
- Settings → Accessibility → Touch → Back Tap
- Assign shortcut to double/triple tap

### 4. Siri
- Say "Hey Siri, Send to WhatsApp Self"
- Works with voice input

### 5. Action Button (iPhone 15 Pro+)
- Assign shortcut to Action Button
- One-press activation

---

## Limitations & Notes

1. **Confirmation Required**: WhatsApp always requires a final tap to send (security feature)
2. **Media Handling**: Images/videos must go through share sheet, not URL scheme
3. **Character Limit**: Very long texts may need to be truncated
4. **URL Encoding**: Special characters must be URL-encoded

---

## Alternative: Message Yourself in WhatsApp

WhatsApp now has a built-in "Message Yourself" feature:
1. Open WhatsApp
2. Tap New Chat
3. Your contact appears at top with "Message yourself" label
4. Pin this chat for quick access

The shortcut approach is faster for sharing from other apps.

---

## Files to Create

| File | Description |
|------|-------------|
| `whatsapp-self-forward.shortcut` | The actual shortcut file (created in iOS) |
| `README.md` | User documentation |
| `PLAN.md` | This planning document |

---

## Next Steps

1. [ ] Create the shortcut in iOS Shortcuts app
2. [ ] Test with various content types (text, URLs, images)
3. [ ] Configure trigger options (share sheet, widget, etc.)
4. [ ] Export and share the shortcut file
5. [ ] Document any iOS version-specific considerations
