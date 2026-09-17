# Bridge compatibility history

`bridge-v1.proto` is the normative protocol-major-1 schema. Fields are never
renumbered or repurposed within this major; removed fields must be reserved.
Compatibility tests exercise the current schema revision and the immediately
preceding supported revision through the same `Envelope` boundary. Revision 1
is the first published schema and is frozen in `bridge-v1-revision-1.proto` and
the golden binary handshake frame.

Revision 2 adds typed Preview and Artifact resource commands. Revision 3 adds
typed, process-correlated GitHub authorization requests and per-device
Notification route management. Revision 4 adds `TerminalScroll`, which pages
the Host-rendered viewport of a controlled terminal (Herdr streams a rendered
viewport, so scrollback lives on the Host). Revision 5 adds the pane working
directory (`Pane.cwd`), the `pane_id` of a resource command and
`READ_WORKSPACE_FILE`, a confined, text-only, size-capped read of one file an
agent referenced in the terminal. Revision 6 changes no message: it widens the
`READ_WORKSPACE_FILE` contract (roots: workspace, home and temporary directories;
images, PDF and HTML besides text; chunked reads via `offset`/`length`), and the
bump lets a client tell a Bridge that still applies the revision-5 rules. Revision 7
adds `SEARCH_WORKSPACE_PATHS`, which searches the same roots `READ_WORKSPACE_FILE`
reads from and returns names and metadata only (`ResourcePathHit`), never contents;
it carries the typed query on `ResourceCommand.query` and reports a budget-truncated
answer through `ResourceResult.truncated`. Revision 8 adds
`LIST_SCREEN_CAPTURE_TARGETS` and `CAPTURE_SCREEN`: the Host lists its displays and
on-screen windows as `ResourceCaptureTarget` (names and sizes only) and captures one of
them, named by `ResourceCommand.target_id`, writing the full PNG to the Host user's
temporary folder and returning its absolute path in `ResourceResult.relative_path` with
a downscaled JPEG preview in `body`. Revision 9 adds
`HandshakeAccepted.bridge_build_id`, which identifies the running Bridge binary rather than
its release: two Bridges that differ only in how something behaves report the same version and
the same revision, so without it a client cannot see that the one it carries is not the one
answering, and a fix that changes no message cannot be offered. A Bridge older than revision 9
sends nothing there, which reads as "cannot tell". Revision 10 adds the typed fields for
`workspace:create`, returning Herdr's authoritative Workspace and root Pane identities, and adds
optional Pane provenance to Preview descriptors. Revisions 1 to 9 are immutable;
Revision 11 extends Workspace creation with a bounded `WorkspaceAgentKind` and
records whether Herdr started that agent in the new root Pane. A schema 10 Host
still creates shell-only Workspaces; the Client never silently downgrades an
agent request.

Revision 12 adds `STAGE_PASTED_FILE`: a file the
operator pasted on the Client travels to the Host in ordered chunks, is recognised by its own
bytes, written under the Host user's temporary folder and answered with the absolute path the
agent reads it from. A schema 11 Host has no such command; the Client refuses locally.

`bridge-v1-revision-12.proto` is the current schema. The compatibility gate
checks the hashes of the prior revisions and exact generation of the current
revision, while golden fixtures continue proving old frames decode.
