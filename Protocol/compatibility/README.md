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

Revision 13 changes no message: it says the Bridge understands the
`workspace:rename:<id>` mutation, which carries the new name in the
`workspace_label` field revision 10 already added. A client that sees an
older revision keeps renaming out of reach instead of having it refused.


Revision 14 adds `host_platform` to `HandshakeAccepted`: the Bridge says what it
runs on — `macos`, `linux` or `windows` — because it is the only party that
knows without being asked. A client otherwise has to open a second SSH session
and read `uname`, which iPhone and iPad pay for in a whole extra connection, and
it needs the answer before offering anything: a macOS Host takes its Bridge from
the signed Mac app, the only copy its screen-recording permission is bound to,
so no other client should offer to send it one. A Bridge older than revision 14
sends nothing, which reads as "cannot tell" and never as a platform; the client
then behaves as it did before.

Revision 15 changes no message: it says the Bridge understands the
`pane:create:<workspace_id>` mutation, which opens a new tab with one Pane in a
Workspace that already exists. It reuses `working_directory` (optional here: the
Bridge falls back on the Workspace's own directory) and `workspace_agent_kind`
from revisions 10 and 11, and answers with the same `workspace_id`, `pane_id`
and agent fields as `workspace:create`. A client that sees an older revision
keeps the action out of reach instead of having it refused.

Revision 16 adds the `LIST_HOST_DIRECTORIES` resource command: the folders inside
one folder of the Host, by name, within the home and temporary directories. It
reuses `path`, `path_hits`, `relative_path` and `media_type`; no message gains a
field. A client that sees an older revision keeps typing the path.

Revision 17 changes no message: it says the Bridge understands the
`pane:split:<direction>:<pane_id>` mutation, where the direction is `right` or
`down`. It splits a Pane that exists and answers like `pane:create`, with the
`workspace_id` and `pane_id` of the Pane the split made and the same agent
fields. The new Pane opens where the Pane it came from is. A client that sees an
older revision keeps the action out of reach instead of having it refused.

Revision 18 adds the `READ_AGENT_USAGE` resource command and `ResourceResult.agent_usage`:
how much of each agent subscription the Host user has consumed, one `AgentUsage` per agent
CLI found on the Host, each with the `AgentUsageMeter`s its plan has. The Bridge asks the CLI
the Host user installed, with the session that installation holds, and sends on percentages,
amounts and reset instants only: never the account, the session or the CLI's own text. It
answers at once with the last Reading it holds and leaves `is_final` unset while a fresher one
is on its way, because a CLI takes seconds and the connection also carries the terminal; a
Reading is reused for five minutes. Which agents, scopes and meters exist is discovered on the
Host at each Reading, and a client renders what arrives. An agent read through a door its
maker does not document says so in `AgentUsage.notice`. One whose reading carries a risk for
the account behind it arrives as `AGENT_USAGE_NEEDS_CONSENT` and its CLI is never run until
`SET_AGENT_USAGE_CONSENT` accepts that notice for the Host (`target_id` names the agent,
`ResourceCommand.consent` is the choice, the Host keeps it and audits it). A client that sees an
older revision shows no usage.

Revision 19 changes no field: it widens `STAGE_PASTED_FILE`. A chunk whose `path`
carries a file name sends that file by name, whatever its bytes: the Host keeps the
name once separators and control characters are gone, caps the file at 256 MiB,
writes the chunks to a hidden partial file as they arrive and moves the finished
file to `sent-<time>-<digest>/<name>` in the same staging folder, pruned with the
pasted files. `length` 0 with the same `idempotency_key` cancels an upload. A
client that sees an older revision sends only images and PDFs, by their bytes.

Revision 20 authenticates the Client device by a proof of its key, in every session, instead of
by the identity it declares. `HandshakeAccepted.device_challenge` carries random bytes the Bridge
made for that connection; the client answers with `DeviceSessionProof`, its P-256 signature over a
statement that binds the domain `northpane-device-session-v1`, the Host ID, the client device ID,
the connection ID, the negotiated protocol and revision, that challenge and the client's own
`host_identity_challenge` (each field behind its length; see the message). The Bridge checks it
against the key it paired and answers `DeviceSessionAccepted` with the grants, `device_not_paired`
for a device it does not know (which then pairs as before) or `device_proof_invalid`; each
challenge takes one attempt. Until then a revision-20 session is granted nothing. Pairing no longer
gives a paired device ID another key (`pairing_identity_conflict`), and the same key pairing again
keeps its grants. A session negotiated at revision 19 or older still authenticates by the declared
identity, but only for a device that has never proved its key: the first proof, or a pairing made
at revision 20, marks the device, and a declared identity no longer stands for it. Every Bridge
process rereads the pairings when they change, before each protected request and at each
heartbeat, and a session whose device is no longer paired loses its terminals and subscriptions
and is answered `device_revoked`. The private endpoint no longer pairs a device
(`pairing_requires_ssh`): anyone on the network can reach it, so a device pairs over SSH or the
Host's own socket and then proves its key over the endpoint. A client that sees an older revision
cannot prove its device, and must not treat such a session as proven.

Revision 21 adds `Pane.last_activity_unix_seconds`: when the Pane's terminal was last written to or
read from, in whole seconds, as the Host's own terminal device records it. The Bridge finds each
Pane's terminal through the processes Herdr starts in it, which carry `HERDR_PANE_ID`; 0 means the
Host cannot tell (Windows, or a Pane whose process it does not find), not that the Pane was never
used. A client orders and groups Panes by it; an older client ignores the field, and a client that
sees an older revision has no time from the Host. Since Bridge 1.0.13 an observation also sends a
snapshot when a Pane's time has moved since the last one sent, checked every 20 seconds: Herdr emits
no event while a process writes without changing status.
