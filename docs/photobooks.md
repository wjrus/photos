# Photobook designer

Photobooks are private, owner-only designs. Open **Photobooks** in site navigation, create a book, and assign photos using the library's bulk **Add to photobook** control, the photo details panel, or **Book photos → Add album photos**. Membership is separate from albums and photo storage. Removing a photo from a book clears its placements and covers, but preserves the library original.

New books start with four blank inside pages, plus front and back covers. Add or remove inside pages as needed; existing books keep their pages. Adding photos creates a pool to choose from; it does not automatically place them.

In **Design pages**, choose a numbered page and drag a photo from the side tray onto the preview. Dropping onto a blank page starts a photo-with-caption layout. Choose a different layout, edit captions and crop positions, and **Save page**. **Add a second photo** opens a second area for another tray photo. Either half of a two-page photo can receive the shared image. Select the front or back cover to place its photo and edit cover text, then **Save cover**.

The tray shows unused photos by default. Placing a photo hides it immediately; replacing or removing a placement returns the old photo if it is not used elsewhere. **Show used photos** allows deliberate reuse. Search and pagination keep the current page's edits intact. Removing a placement preserves book membership and the library original. On touch screens or with a keyboard, select a tray photo and then its destination instead of dragging.

Preview edits are not saved until the Save button is used. Switching pages warns before discarding unsaved changes. Page text and captions are independent of the library photo's caption; placing a photo copies its description into an empty caption field and preserves existing caption text.

Layouts: blank, full-page photo, whole photo with whitespace, photo with caption, two photos side by side, two photos stacked, text, and one photo across two pages. Independently designed facing pages support arrangements such as a full-page image opposite a bordered image and caption. Book settings control size, front and back photos, cover text, background and text colors, and the saved spine label.

Cover text overlays the artwork directly, with no solid caption panel. Each cover has its own **Cover typography** settings: five embedded fonts (Cormorant Garamond, its italic, Noto Serif, Lato Light, and Noto Sans), text size, text color, shadow color, optional shadow, alignment, and top/middle/bottom placement. **Classic**, **Editorial**, and **Minimal** presets provide starting compositions. Full-photo covers start with white type and a subtle dark shadow; whitespace covers use the book's text color. Changing colors manually preserves them when changing the photo layout. Title and subtitle share the cover style, with a proportionally smaller subtitle.

On photo-with-caption and two-photo pages, turn off **Show photo captions** to remove the caption areas and expand the photos. Caption text remains saved and returns when enabled again. Full-page, fitted-photo, and spread layouts already omit captions; text pages always retain their page text.

## Prodigi layflat artwork

Source: [Prodigi layflat file setup guidelines](https://support.prodigi.com/hc/en-us/articles/17150478672540-Layflat-photo-books-File-set-up-guidelines), checked October 3, 2026. Supported sizes:

| Format | Single page size |
| --- | --- |
| Square | 210 × 210 mm |
| Large square | 297 × 297 mm |
| A4 landscape | 297 × 210 mm |

The first PDF page is the front cover. The second PDF page is inside page 1, on the right. Inside pages 2 and 3 form the first facing spread. The final PDF page is the back cover. The inside covers are unprinted and added by the printer. A two-page image shares one crop and is exported as two individual PDF pages, with no bleed or crop marks. Print checks reject a spread starting on a right-hand page; adding a new spread inserts a blank page first when necessary. Converting or reordering existing pages can require adjustment to restore spread alignment and an even page count.

Print exports support 18–120 inside pages, producing 20–122 PDF pages including covers. Smaller designs remain editable without adding filler pages; the minimum and even page count are enforced when generating a print PDF. That conservative range stays within the advertised 18–122-page product and file guide while their exact page-count convention is confirmed for quoting/ordering. The exported PDF's actual count is shown explicitly.

Original files are decoded with libvips, oriented using EXIF, converted to RGB, flattened when transparent, stripped of embedded metadata, and downsampled only when above the 300 DPI target. Crops use the saved horizontal and vertical focus. Preview dimensions project only EXIF orientation and pixel dimensions rather than loading the entire metadata document. The selected bundled SIL OFL fonts are embedded; characters unsupported by the selected font, including many emoji, block export. Text wrapping, alignment, color, vector shadow offsets, and page geometry are shared between preview and PDF. All caption and cover text boxes stay inside the 10 mm safety area. Already queued version-one export snapshots retain their original cover panels and font.

**Print checks & PDF → Generate print PDF** queues a snapshot of the saved design. Missing/unavailable photos, text overflow, invalid spread placement, and page-count errors block generation. Low resolution needs explicit acknowledgement; unknown dimensions are checked against the decoded original during export. An unexpected resolution failure can be retried with acknowledgement from its failed-export entry.

The output meets the guide's embedded-font and flattened-transparency alternative; it does not assert certified PDF/X-4 conformance. Representative PDFs have been rendered and checked locally for dimensions, font embedding, Unicode text, page order, captions, and spreads. A real Prodigi sample and vendor acceptance remain to be verified before automated ordering.

## Covers, spine, and future ordering

Front/back covers are included in the PDF. The spine label is stored in the design and export snapshot, but is **not spine artwork**. For manual orders, enter that label and the desired spine colors in Prodigi's order form. API spine artwork requires dimensions based on page count and the selected production lab; it will be generated when that integration is added. No Prodigi credentials, uploads, charges, or orders are involved in this feature.

## Operations and deployment

The initial migration adds four tables and foreign keys; it does not backfill or change existing photo/album data. The typography migration adds front/back style JSON objects and a caption visibility flag defaulting to enabled. Existing books keep their captions. Use the normal Rails image/deployment process and database migration. No new environment variables or analysis-service rebuild are needed. Prawn and its dependencies are locked in Gemfile.lock; all fonts are bundled with their licenses under `vendor/fonts`. Asset precompilation includes the preview fonts.

`PreparePhotoBookExportJob` uses the existing default queue and limits PDF generation to one job at a time in Solid Queue to bound memory consumption. PDFs are stored with Active Storage. Progress and export history appear on the book page. Retried jobs can recover a processing export, duplicate completed deliveries do not regenerate it, and deleting a book discards its queued exports. Removing a book also removes its PDF attachments through the normal Active Storage lifecycle.

Download bytes are streamed through an owner-authorized controller, without public Active Storage links. Downloads and generation recheck that source photos remain assigned, unrestricted, unarchived, and attached to the same original blob captured by the snapshot. Moving a used photo into Private/Archive or removing it from the book makes earlier PDFs unavailable. Previously downloaded files cannot be revoked.

Verification commands:

```sh
rbenv exec bundle exec rails db:migrate
rbenv exec bundle exec rails test
rbenv exec bundle exec rails test:system
rbenv exec bundle exec rubocop
rbenv exec bundle exec ruby bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
rbenv exec bundle exec bundler-audit check --update
rbenv exec bundle exec ruby bin/importmap audit
```
