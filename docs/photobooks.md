# Photobook designer

Photobooks are private, owner-only designs. Open **Photobooks** in site navigation, create a book, and assign photos using the library's bulk **Add to photobook** control, the photo details panel, or **Book photos → Add album photos**. Membership is separate from albums and photo storage. Removing a photo from a book clears its placements and covers, but preserves the library original.

New books start with four blank inside pages, plus front and back covers. Add or remove inside pages as needed; existing books keep their pages. Adding photos creates a pool to choose from; it does not automatically place them.

In **Design pages**, choose a numbered page and drag a photo from the side tray onto the preview. Dropping onto a blank page starts a photo-with-caption layout. Choose a different layout, edit captions and crop positions, and **Save page**. **Add a second photo** opens a second area for another tray photo. Either half of a two-page photo can receive the shared image. Select the front or back cover to place its photo and edit cover text, then **Save cover**.

Every page opens in a larger **Single page** view, including each half of a two-page photo. The small book marker highlights the left or right side and labels the printed page number; covers have their own marker. **Facing pages** shows the adjoining page or unprinted inside cover for checking a spread. Switching preview views preserves unsaved edits and does not save or change the design. Saving a two-page photo keeps the selected half open.

The tray shows unused photos by default. Placing a photo hides it immediately; replacing or removing a placement returns the old photo if it is not used elsewhere. **Show used photos** allows deliberate reuse. Search and pagination keep the current page's edits intact. Removing a placement preserves book membership and the library original. On touch screens or with a keyboard, select a tray photo and then its destination instead of dragging.

Preview edits are not saved until the Save button is used. Switching pages opens an in-app confirmation before discarding unsaved changes. Removing a page, book photo, or book uses the same modal pattern, with Cancel, Escape, and keyboard focus management. Removing a saved two-page photo removes both of its pages. Page text and captions are independent of the library photo's caption; placing a photo copies its description into an empty caption field and preserves existing caption text.

Layouts: blank, full-page photo, whole photo with whitespace, photo with caption, two photos side by side, two photos stacked, text, and one photo across two pages. Independently designed facing pages support arrangements such as a full-page image opposite a bordered image and caption. Book settings control size, front and back photos, cover text, background and text colors, and the saved spine label.

Cover text overlays the artwork directly, with no solid caption panel. Each cover has its own **Cover typography** settings: five embedded fonts (Cormorant Garamond, its italic, Noto Serif, Lato Light, and Noto Sans), text size, text color, shadow color, optional shadow, alignment, and top/middle/bottom placement. **Classic**, **Editorial**, and **Minimal** presets provide starting compositions. Full-photo covers start with white type and a subtle dark shadow; whitespace covers use the book's text color. Changing colors manually preserves them when changing the photo layout. Title and subtitle share the cover style, with a proportionally smaller subtitle.

With **Full cover photo**, drag the placed photo directly on the preview to position the crop. Touch dragging works too. Use the horizontal/vertical sliders for precise adjustments, or focus the photo and use arrow keys (Shift moves ten steps). **Center photo** resets the crop. Movement stops at the photo edges so the cover stays filled; a photo matching the cover proportions has no cropped edges to move. Front and back positions are independent, remain editable until **Save cover**, and carry through to the print PDF. Replacing a cover photo starts centered. Whitespace covers show the whole photo and stay centered.

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

## Prodigi ordering

Front/back covers are included in the book PDF. **Saved PDFs → Print with Prodigi** starts an order for that immutable export. Choose copies, delivery, and currency to get a quote. Review the downloadable book and spine PDFs, address, and estimated total, then confirm. Draft orders can be discarded using the app's confirmation modal. Confirmed orders and their books are retained for order history. Changing a book later does not change its export or order.

Quotes fetch current product details and validate dimensions, destination, finish, and print areas. The A4 landscape default is Prodigi's published `BOOK-FE-A4-L-LF-G` layflat sample code. Square sizes require the exact layflat SKU from your account catalogue; do not guess these codes. Products needing additional artwork or an ambiguous finish are rejected. No API calls occur just from viewing a book or order: quotes and status refreshes are explicit, and webhooks also refresh status.

Where the product accepts a spine, Photos obtains its width from `/products/spine` using the exported PDF's actual page count and destination. It generates a separate PDF at that width and the book's height, with the saved spine label and book background/text colors, embedded Noto Sans, and text rotated along the spine. The font shrinks to fit. Unsupported characters block quoting. Review the spine PDF before submission; actual vendor acceptance still needs a sandbox test and a printed sample. For manual ordering, use Prodigi's spine tool instead.

Quotes expire after one hour and include books and shipping. Taxes, duties, and exchange fees can add to the final amount. The reviewed quote is checked again during confirmation to prevent another tab's quote refresh from silently changing the price. Sandbox orders are not fulfilled or charged. Live orders are charged to your Prodigi account, so the live submit button explicitly says **Place paid order**.

### Server configuration

Keep credentials in the server's ignored `.env.production` (or ignored local `.env` for development), never in Git or browser JavaScript. Compose already passes `.env.production` to both web services and the worker. No separate service or analysis rebuild is needed.

```dotenv
PRODIGI_ENVIRONMENT=sandbox
PRODIGI_SANDBOX_API_KEY=
PRODIGI_LIVE_API_KEY=
PRODIGI_LIVE_ORDERING_ENABLED=false
PRODIGI_PUBLIC_BASE_URL=https://photos.example.com
PRODIGI_WEBHOOK_SECRET=
PRODIGI_SKU_LANDSCAPE_A4=BOOK-FE-A4-L-LF-G
PRODIGI_SKU_SQUARE_210=
PRODIGI_SKU_SQUARE_297=
```

1. Obtain the sandbox key from your [Prodigi sandbox account](https://dashboard.sandbox.prodigi.com/) and put it in `PRODIGI_SANDBOX_API_KEY`. Your normal Prodigi dashboard key belongs in `PRODIGI_LIVE_API_KEY`; the environments may use different credentials. Live quotes can be requested with `PRODIGI_ENVIRONMENT=live` while paid ordering remains disabled.
2. Set `PRODIGI_PUBLIC_BASE_URL` to Photos' externally reachable HTTPS origin, without a path or trailing query. This is configured on the server and never inferred from an incoming request's Host header.
3. Generate a webhook secret locally with `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'` and put the result in `PRODIGI_WEBHOOK_SECRET`.
4. Deploy through the normal authorized release process, including the new order-table migration. In **Print with Prodigi → Prodigi webhook setup**, copy the generated URL into **Prodigi → Settings → API → Webhook URL** for the matching environment. The URL has the form `https://photos.example.com/webhooks/prodigi/sandbox?token=YOUR_SECRET`. Each submitted order also supplies this callback URL automatically.
5. Confirm a sandbox order and check its status and artwork acceptance. Only after testing, set `PRODIGI_ENVIRONMENT=live` and `PRODIGI_LIVE_ORDERING_ENABLED=true` for paid ordering. Existing sandbox orders retain their sandbox identity and credentials even after switching to live. No order is submitted merely by configuring keys or fetching a quote.

The existing default Solid Queue worker handles submission and authenticated status refreshes. The account key never reaches the browser. Open order pages check only cached database state and refresh the screen when a job or webhook updates it. On confirmation, the exact API body and a durable UUID idempotency key are frozen. All retries use that same body and key, including after a timeout. **Retry same order** also recovers an interrupted enqueue; do not create a new order to recover an uncertain submission. Errors never expose vendor response bodies or private artwork URLs. Manage cancellations or manufacturing issues in the Prodigi dashboard.

Artwork remains behind the normal owner download route before confirmation. After confirmation, Prodigi receives purpose-bound signed URLs for only that order's book/spine PDFs, valid for 30 days. These routes stream bytes and recheck original-source privacy/availability. Moving source photos into Private/Archive, replacing originals, or removing them from the book revokes subsequent downloads; files already fetched by the printer cannot be recalled. Expired or unavailable assets block new submission attempts. The webhook uses a secret URL and treats callback content only as a notification: it fetches known orders from the fixed authenticated API endpoint rather than trusting callback status or source URLs. Duplicate notifications are harmless. Unknown orders and other-environment callbacks do not trigger API requests.

Delivery details, callback URLs, and artwork tokens are filtered from Rails parameter logs. The bundled Photos proxy's access log omits query strings and referer URLs. Keep upstream/error logs private and configure any external reverse proxy to redact query strings for these endpoints. Rotating `PRODIGI_WEBHOOK_SECRET` requires updating dashboard settings; older confirmed orders retain their original callback URL, so use explicit status refresh for them. Rotating Rails signing keys invalidates outstanding artwork URLs and requires reconciling affected orders in Prodigi before placing replacements.

API contract: [Prodigi v4 reference](https://www.prodigi.com/print-api/docs/reference/). Account-specific quotes, webhook delivery, artwork acceptance, and billing have not been verified without configured credentials. Test fakes cover these paths without creating vendor orders.

## Operations and deployment

The initial migration adds four tables and foreign keys; it does not backfill or change existing photo/album data. The typography migration adds front/back style JSON objects and a caption visibility flag defaulting to enabled. Existing books keep their captions. The cover-position migration adds four bounded position values, defaulting to centered so existing covers retain their crops. The order migration adds one table with a unique idempotency reference and environment-scoped remote order identifier. Use the normal Rails image/deployment process and database migration. Prodigi configuration is optional for designing/downloading books; no analysis-service rebuild is needed. Prawn and its dependencies are locked in Gemfile.lock; all fonts are bundled with their licenses under `vendor/fonts`. Asset precompilation includes the preview fonts.

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
