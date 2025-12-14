# File Autoorganizer

A macOS app that scans a source folder of PDF statements and proposes moves into matching destination subfolders based on content similarity. It infers naming patterns and proposes new filenames with dates that match existing conventions in the destination folders.

## Features

- Scan a source folder for PDF statements
- Discover destination subfolders and aggregate their “vocabulary” from PDF content
- Compute a similarity score for each source PDF to the best destination subfolder
- Preview proposed moves with confidence scores
- Move selected files, automatically renaming them to match existing patterns
- Quick Look integration (Space bar) for fast PDF previews
- Security-scoped bookmarks to remember chosen folders across launches
- Console diagnostics for transparency and troubleshooting

## How it works (high level)

1. Destination profiling
   - The app enumerates all PDFs under the Destination Root.
   - It extracts tokens from the first 3 pages of each PDF (lowercased words, punctuation trimmed).
   - It also includes tokens derived from the destination folder name to capture institution names.
   - It aggregates these tokens per subfolder.

2. Scoring
   - For each source PDF, the app extracts tokens from the first 3 pages.
   - It computes a Jaccard similarity between the source tokens and a destination subfolder’s aggregated tokens.
   - It adds:
     - +0.2 if the destination folder has PDFs (extension match)
     - +0.1 if any tokens from the destination folder’s name intersect the source tokens (anchor boost)
   - The final score is displayed as a percentage in the UI (e.g., 32.2%).

3. Thresholding and selection
   - The Threshold slider controls which proposed moves are preselected.
   - Only proposals with a score >= threshold are auto-selected for moving.

4. Renaming
   - The app infers a naming pattern from existing PDFs in the destination folder (e.g., prefix + date + suffix).
   - It extracts a date from the source PDF content when possible; otherwise falls back to file creation/modification date.
   - It proposes a new filename and ensures uniqueness in the destination folder.

## Requirements

- macOS (built and tested with Xcode 26)
- PDFKit / Quick Look frameworks (already linked by the project)
- Access to the folders you select (granted via NSOpenPanel)

## Getting Started

1. Build and run in Xcode (Command+R).
2. In the app:
   - Click “Choose…” next to Source and select your source folder.
   - Click “Choose…” next to Destination Root and select the parent folder containing destination subfolders.
   - Adjust the Threshold as desired (lower thresholds select more matches).
   - Click “Scan”.
3. Review the proposed moves:
   - Each row shows the source filename, proposed destination, proposed new name, and a confidence percentage.
   - Click “Preview” or press Space to open Quick Look.
   - Toggle selections as needed.
4. Click “Move Selected” to perform the moves.

## Understanding the Score

- The score is a confidence measure for the match between a source PDF and a destination subfolder.
- It is computed as:
  - Jaccard similarity (content tokens) + extension bonus (+0.2) + folder-name anchor bonus (+0.1 if any anchor overlap).
- Displayed as a percentage (e.g., 32.2%).
- The Threshold slider uses the same scale.

## Permissions & Bookmarks

- The app uses security-scoped bookmarks to persist access to the folders you choose.
- If you see errors like “Failed to save bookmark” or “Could not open() the item”:
  - Re-select the Source and Destination Root using the “Choose…” buttons.
  - Make sure you select the parent folder that contains the destination subfolders.
  - If problems persist, try a different location (e.g., Desktop) to rule out permission issues.

## Tips for Better Matching

- Ensure destination folders contain representative PDFs of the institution.
- If statements are scanned images without text, content extraction may be limited.
- The app reads the first 3 pages; you can increase this in code if needed.
- Consider lowering the threshold (e.g., 25–30%) when formats vary significantly over time.

## Troubleshooting

- No proposals or very low scores
  - Verify the Destination Root is correctly selected (parent folder).
  - Check the Xcode console for “DEST FOLDER:” lines and token counts.
  - If token counts are zero, PDFs may be non-text or access failed.

- Score in console differs from UI
  - Clean build (Shift+Command+K), run, clear console, then Scan once.
  - Each row logs “UI ROW: <filename> score: <value>” when it appears; it should match the “SOURCE:” debug line.

- Bookmark errors
  - Re-select folders via the UI; these errors affect persistence, not immediate scanning.
  - Ensure your app has necessary access; using NSOpenPanel should grant scoped access.

## Console Diagnostics

The app prints:
- Destination summaries:
