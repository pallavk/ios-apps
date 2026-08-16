# WhatsApp Self-Forward Shortcut

A simple iOS Shortcut to quickly forward content to your own WhatsApp account with one tap.

## Quick Setup (5 minutes)

### Step 1: Open Shortcuts App
Open the **Shortcuts** app on your iPhone.

### Step 2: Create New Shortcut
1. Tap **+** in the top right
2. Tap **Add Action**

### Step 3: Add These Actions

**Action 1 - Receive Input:**
- Search for "Receive"
- Select **Receive [input] from [Share Sheet]**
- Tap "Any" and select: Text, URLs
- Enable "Show in Share Sheet"

**Action 2 - Set Your Number:**
- Search for "Text"
- Add **Text** action
- Enter: `whatsapp://send?phone=YOUR_NUMBER&text=`
- Replace `YOUR_NUMBER` with your number (e.g., `14155551234`)

**Action 3 - Combine:**
- Search for "Combine"
- Select **Combine Text**
- Set: [Text from step 2] + [Shortcut Input]

**Action 4 - Open WhatsApp:**
- Search for "Open"
- Select **Open URLs**
- Set input to: [Combined Text]

### Step 4: Name & Save
1. Tap the dropdown at top → **Rename**
2. Name it: "Send to Self"
3. Tap **Done**

## Usage

### From Any App:
1. Tap **Share** button
2. Scroll down and tap **Send to Self**
3. WhatsApp opens with your message ready
4. Tap **Send** in WhatsApp

### From Home Screen:
1. Long-press the shortcut in Shortcuts app
2. Tap **Add to Home Screen**
3. Tap the icon anytime to send clipboard content

## Phone Number Format

Use international format WITHOUT the + sign:
- US: `14155551234`
- UK: `447911123456`
- India: `919876543210`
- Australia: `61412345678`

## Troubleshooting

**"WhatsApp not opening"**
- Make sure WhatsApp is installed
- Check the URL format is correct

**"Number not recognized"**
- Ensure no spaces, dashes, or + in number
- Include country code

**"Special characters not working"**
- Some characters need URL encoding
- The shortcut handles basic text; complex content may need adjustments

## See Also

- [PLAN.md](./PLAN.md) - Detailed technical planning document
