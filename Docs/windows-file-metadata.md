# Windows file metadata

Workspace path search, file reads and folder listing use WinSDK
`GetFileAttributesExW` on Windows. Foundation URL resource values in Swift 6.3.2
can trap on a file larger than the signed 32-bit range, including when only
`isDirectory` is requested. An automatic Workspace icon search could therefore
terminate the Bridge and disconnect an otherwise working terminal.

The regression was reproduced with a synthetic sparse file of 3,355,443,200
bytes: a single Foundation `isDirectory` query exits with an illegal instruction.
The corrected path joins the high and low size fields as an unsigned 64-bit
value and clamps only when converting to Swift `Int`. FILETIME is converted
from the Windows epoch to a Foundation date.

Directory enumeration requests no Foundation resource properties on Windows.
Reparse points, including junctions, are treated as links and refused by path
search and file reads. Existing roots, secret filters, depth/time budgets and
content size limits remain in force. An oversized file is searchable by name
but rejected before its content is read. POSIX Hosts continue using Foundation.

`LargeWorkspaceFileTests` checks a sparse file above 2 GiB, its size and date,
name search, oversized-read refusal, folder listing and symbolic-link refusal.
The Windows fixture marks the file sparse before extending it, so the test
does not allocate several gigabytes. Version 1.0.15 contains the fix; the wire
schema remains 22.
