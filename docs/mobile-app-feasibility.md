# Mobile app feasibility

Reviewed October 4, 2026. This is a feasibility assessment, not an implementation
plan or a claim that native behavior has been tested. No mobile app has been
started.

The server API has subsequently been implemented. See [Mobile API v1](mobile-api.md)
for its authentication, browsing, metadata/maps, bulk operations, media delivery,
and upload contract. Native app behavior and the platform questions below remain
to be validated.

## Proposed experience

A reusable mobile client would connect to an independently hosted installation
of Photos using a server URL and email/password. One app could support anyone
running compatible Photos code without requiring a central account service.

Ionic/Angular with Capacitor is a reasonable choice, following the approach in
the sibling `tadlMobile7` project. Ionic would provide browsing and controls;
native iOS modules would handle photo-library access, background transfers, and
external-display presentation.

| Capability | Assessment |
| --- | --- |
| Connect using server URL and email/password | Straightforward with a mobile authentication API |
| Browse photos, albums, and search | Good fit for Ionic |
| Upload selected photos | Feasible using existing server import infrastructure with a mobile API |
| Show photos on a TV while independently browsing on the phone | Feasible through native external-display support; hardware validation required |
| Automatically back up new photos | Feasible with platform limitations; likely the largest engineering effort |

## Existing server foundations and gaps

The current code provides:

- Email/password authentication in `SessionsController` and `User`.
- Access-controlled image and video endpoints in `PhotosController`.
- Chunk upload, status, and completion endpoints in `UploadChunksController`.
- Original import, checksum computation, derivative generation, and background
  processing.
- Owner/viewer roles and private-by-default uploads.

These are useful foundations, but they do not constitute a complete mobile API.
Authentication currently uses browser sessions, and many operations return HTML
or redirects. A mobile client needs explicit JSON contracts for authentication,
browsing, upload progress, and failures while preserving existing authorization
and privacy rules.

Uploads are currently **owner-only**. Signing in as a viewer does not permit
automatic backup. Supporting additional uploaders would require an explicit
permission decision and server changes.

The existing chunk-upload staging expires after **30 minutes**. That lifetime
needs reconsideration for background work that iOS may delay. Server chunking is
also a different protocol from Apple's newer resumable-upload support.

## Connecting to independent installations

Recommended design considerations:

- Exchange login credentials for a revocable device token. Store tokens in
  Keychain on iOS, rather than retaining the account password in ordinary app
  storage. Token expiration, renewal, and revocation must accommodate queued
  background transfers.
- Associate credentials, cached content, and pending uploads with the selected
  server and account. Changing servers must never redirect an existing upload
  queue to the new installation.
- Require trusted HTTPS and account for servers available only through a LAN or
  VPN. An unreachable server means backup waits until connectivity returns.
- Keep credentials scoped to the intended server; handle redirects and host
  changes without forwarding credentials to an unrelated destination.
- Provide a server capability/API-version endpoint so the app can detect
  incompatible installations and unsupported features.
- Keep the app's interface bundled locally and access the server through defined
  API contracts. Loading arbitrary server-provided executable content into an
  interface with native capabilities would introduce a separate trust boundary.

## AirPlay and independent TV presentation

The desired behavior is a separate phone controller and TV display: the TV keeps
showing the selected photo or slideshow while the user browses on the phone.

UIKit supports presenting separate content on displays connected through AirPlay
or a physical cable. A dedicated native external-display scene could render
photos while Ionic handles selection, slideshow controls, and browsing on the
phone. This requires native integration with Capacitor and testing on actual
iPhones and receivers. Receiver compatibility, disconnect/reconnect behavior,
and what happens when the app backgrounds or the phone locks remain unverified.
See [Apple's connected-display documentation](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display).

Video playback has a separate AirPlay path through Apple's media player and
route picker. A plugin supporting video AirPlay should not be assumed to support
independent still-photo presentation. See
[AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview).

## Automatic photo backup on iOS

Backup has two distinct jobs: discover new photo-library assets, then transfer
assets already queued. The product should promise opportunistic backup with
visible status and retry behavior, rather than immediate upload of every new
photo under all conditions.

### Conventional background transfers

A conventional implementation would combine native PhotoKit access, a
persistent upload queue, and background `URLSession` transfers. Background
transfers can continue while the app is suspended. If the user force-quits the
app, iOS cancels the session's background transfers and does not automatically
relaunch the app; the user must open it again. See
[Apple's background-session documentation](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)).

Discovery and scheduling are still constrained by iOS. Capacitor's Background
Runner does not provide an always-running JavaScript process: execution time is
limited and requested schedules are not guaranteed. See
[Background Runner limitations](https://capacitorjs.com/docs/apis/background-runner#limitations-of-background-tasks).

### PhotoKit background-upload extension

Apple provides a PhotoKit background resource upload extension starting with
iOS 26.1, intended for backup while users switch apps or lock their devices.
It requires full photo-library access and native extension code; limited access
is insufficient for enabling this extension. The system schedules work according
to network, power, and device conditions.

An important unresolved constraint is the required `BackgroundUploadURLBase`
entry in the extension's bundled configuration. Apple describes this as the
upload server's base URL, used for network access validation. This creates a
potential conflict with a reusable app accepting arbitrary server URLs at
runtime. **Support for arbitrary user-selected hosts through this extension is
unproven and must be validated before choosing it.** This is not a conclusion
that the mobile app is infeasible: conventional background transfers remain an
option.

The extension's resumable transfers use Apple's documented support for the HTTP
resumable-upload draft, including capability negotiation and an informational
response. Photos' existing chunk protocol is not equivalent. Adopting this
mechanism would require compatible server handling and validation through the
actual HTTP server and reverse proxy.

See [Apple's background asset upload documentation](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background).
API availability and configuration requirements should be rechecked when work
begins; the documentation also covers newer OS-specific APIs.

## Product and data decisions

- **Backup scope:** new assets from enrollment onward, selected albums, or the
  entire existing library. Explain the initial backlog before uploading it.
- **Permission:** support selected-photo/manual upload when full library access
  is unavailable; explain which automatic-backup features require broader access.
- **Original fidelity:** decide how to preserve HEIC, videos, Live Photo image/
  video pairs, edits, timestamps, and GPS. Uploading an original and uploading
  its currently edited appearance are different operations. Existing image/video
  support does not prove Live Photo pairing or edit preservation.
- **iCloud assets:** handle originals that must first be downloaded from iCloud,
  including unavailable assets, bandwidth, and temporary disk space.
- **Retries and duplicates:** persist asset tracking and upload state; make server
  completion idempotent and deduplicate retries and uploads from multiple devices.
  A computed checksum alone does not establish an idempotent upload contract.
- **Network policy:** offer Wi-Fi-only/cellular preferences and consider charging
  preferences, large videos, storage limits, and authentication failures.
- **Privacy:** retain private-by-default uploads and existing access rules for
  originals, metadata, restricted photos, and display derivatives. Isolate local
  caches by account and define cleanup on sign-out.
- **Deletion:** initially treat this as backup. Deleting a photo from the phone
  should leave its server copy intact. Synchronized deletion would be a separate,
  explicitly designed feature.
- **Other platforms:** Android would require its own background-work and photo
  permission design. iOS AirPlay support does not imply Android casting support.

## Recommended first validation when development is authorized

Keep Ionic/Capacitor as the initial framework choice. Before building the full
interface, test two small native integrations on a physical iPhone:

1. Independent photo/slideshow presentation on an AirPlay receiver while browsing
   on the phone, including connection loss and lifecycle transitions.
2. Background backup to a user-selected HTTPS host, including new-asset discovery,
   delayed execution, interruptions, token renewal, retries, and duplicate
   prevention. Specifically establish whether the PhotoKit upload extension can
   support arbitrary installation URLs.

These checks would resolve the largest uncertainties. A web build or simulator
test alone would not establish either behavior.
