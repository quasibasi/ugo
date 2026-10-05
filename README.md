# Ugo

A personal notes app for the Mac. Native SwiftUI, SwiftData on disk,
Markdown rendered in place as you type. Todos are notes: any note can
hold a checklist. Written so the same code compiles for iPhone and iPad.

## Build

Two ways, same result.

**Xcode.** Open `Ugo.xcodeproj`, pick the *My Mac* destination and run.
The first time on a fresh Xcode you need to accept its license once:

```bash
sudo xcodebuild -license accept
```

**Script.** Compiles with `swiftc` directly and assembles `Ugo.app`, no
Xcode build system involved. Works even before the license is accepted.

```bash
scripts/build.sh release --install --run
```

That moves the optimised build to `~/Applications/Ugo.app`, quits any Ugo
already running and opens the new copy. Keep it that way: macOS treats each
bundle path as a separate app, so a second copy opened beside the first
shows up as a second Ugo. `scripts/build.sh debug --run` gives an
unoptimised build under `build/debug` for debugging; it too quits the
running copy first, and the next build removes that bundle again.

## First launch

Ugo keeps its own database. On first launch it offers to import a folder
of Markdown files, and finds an open Obsidian vault by itself: folders
become folders, each `.md` file becomes a note. After that the two are
separate; nothing is written back to the folder. Settings has an Import
button for bringing in another folder later, and existing titles in the
same folder are skipped.

## Using it

| Action | Shortcut |
| --- | --- |
| New note in the current folder | ⌘N |
| New folder inside the selected folder, named as you type | ⇧⌘N |
| Quick open: find a note or a checklist line, or create by name | ⌘P |
| Create the typed name from quick open | ⌘↩ |
| Open the highlighted note in section zen on a new empty `##` at its top | ⇧↩ in quick open |
| Open the highlighted note and put the cursor in it | ↩ with the sidebar focused |
| Open the selected note in a tab of its own | ⌘/ |
| Open the selected note in a split | ⌘. |
| Close the tab | ⌘W |
| Close the window | ⇧⌘W |
| Next or previous tab in the pane | ⇧⌘] and ⇧⌘[ |
| First to ninth tab in the pane | ⌥1 to ⌥9 |
| Show or hide the sidebar | ⌘\ |
| Zen mode: the note alone fills the window, and back | ⌘↩ |
| Section zen: only the `#` or `##` section the caret is in, and back | ⇧⌘↩, Esc to leave |
| Next or previous section in section zen | ⌥⌘↓ and ⌥⌘↑ |
| Present the note full screen, a slide per `#` and `##` heading | ⇧⌘P |
| Find inside a note | ⌘F |
| Link the selected text, or change the link the caret is in (empty URL removes it) | ⌘K |
| Link the selected text by pasting a URL over it | ⌘V |
| Open a link | ⌘-click |
| Move the highlighted note to the trash | ⌫ with the sidebar focused |
| Move the highlighted folder and its notes to the trash | ⌫ with the sidebar focused |
| Open favourite note 1 to 9 | ⌘0 … ⌘8 |
| Settings: theme, editor font size, import, favourites | ⌘, |

The window has no toolbar. The sidebar on the left is one column: the
folder tree with note counts, and inside each open folder its subfolders
and then its notes, newest first. The note open in the focused pane is
highlighted, and the folders above it open by themselves. The note opens
on the right in a centred column with a title field. The + at the top of
the sidebar makes a note, and its foot shows Ugo's face and how many notes
there are. ↑ and ↓ move through the sidebar's rows, → opens a folder, ←
closes it or steps out to the folder above, and ↩ opens or closes a folder.
⌘↩ puts the note in the focused pane into zen mode: the sidebar,
the other panes and the tabs go away and the note fills the window. ⌘↩
again brings everything back as it was. ⇧⌘↩ goes one step further and
shows only the section the caret is in: every `#` and `##` heading starts
one, and text above the first heading is a section too. It stays
editable, and the edits land in the note. ⌥⌘↓ and ⌥⌘↑ move to the next
or previous section, and ⇧⌘↩ or Esc shows the whole note again with the caret
where it was. In quick open the same keys
still create a note. ⌘\ shows and hides the sidebar; drag its edge to
change its width.

Right-click a folder to rename it or make a folder inside it, or right-click
empty space in the sidebar for a new top-level folder. Rename Folder is
also in the Edit menu. The name turns into a text field: ↩ keeps it, Esc
backs out, and a name another folder beside it already has gets a beep.

To move a note or a folder, drag it onto another folder in the sidebar,
or onto empty space to put it at the top level. Dropping on a note moves
into that note's folder. A closed folder opens if the drag rests on it for
a moment. Folders take everything inside them along, and can't go into
themselves. Move To in the right-click menu does the same without the
mouse. A name already used where it lands gets a number, as a new
folder's would.

To delete a folder, pick Move to Trash from its right-click menu or the
Edit menu, or press ⌫ with the folder highlighted in the sidebar. An empty folder goes
at once; one with notes asks first. Its notes and subfolders go with it:
the notes are trashed like any other, the folders are removed.

Open notes sit as tabs in the editor's header strip. A click on a note in the sidebar
shows the note in the pane's preview tab, the one with the italic title,
and the next click replaces it. The arrow keys only move the highlight in
the sidebar; ↩ opens the highlighted note and puts the cursor in it. To keep
a note, press ⌘/, double-click its tab, or pick Open in New Tab from the
right-click menu; the note the preview had replaced gets its tab back. ⌘.
or Open in Split opens the note in a pane of its own: up to three columns
side by side, then a second pane under each column, six panes at most. Both
shortcuts act on the highlighted note, so you can arrow to a note and open
it beside the one you are reading. Each pane has its own tabs, and the pane
whose active tab is underlined in colour is the one the list and the keyboard act on. A
note is open in one place at a time, so opening it again just goes there.
Closing a pane's last tab closes the pane. Drag the hairline between panes
to resize them; the panes keep their proportions when the window or the
sidebar changes width. The open tabs and pane sizes come back on the
next launch.

Notes are Markdown. Headings, lists, `- [ ]` checklists, quotes, code,
bold, italic, strikethrough and links render in place. The markers are
hidden on every line except the one holding the cursor, where they show
dimmed so you can edit them. Bullets, numbers, checkboxes and quote bars
are drawn where the markers were, and clicking a drawn checkbox ticks it.

Lists behave as in Notion. List markers stay hidden even on the caret
line. Typing `[]` at the start of a line, or after a bullet, makes it a
checklist item. ↩ continues the list, and ↩ on an empty item leaves it, one level at
a time. ⇥ and ⇧⇥ nest an item together with everything under it. ⌫ at the
start of an item turns it into plain text. Numbers are always consecutive
and are rewritten in the Markdown after each of these keys. Nested levels
count 1, a, i.

Columns sit side by side, as in Notion. Type `/columns` on a line of its
own and press ↩ for two, or `/3 columns` (also `/3col`, `/columns 4`) for
up to six. In the Markdown a block of columns is

```
::: columns
First column
+++
Second column
:::
```

and any of it can be typed by hand; a block counts once it is closed.
Each column is edited in place and holds any Markdown. ↑ and ↓ move
between the note and the column under the caret, ← and → at either end
of a column move to the next one, and ⌫ in an empty column takes it out;
with one column left, its text goes back into the note. Headings inside
columns don't start sections or slides, and slides show the columns one
after another.

Settings → General has five themes, each shown as a small picture of the
window: System follows the macOS appearance, Paper is always light, and
Midnight, Ugo (graphite with the logo's red) and Ink are dark. A theme
colours the whole window, from the sidebar to the editor.

Up to nine notes can be favourites. Pick them in Settings under
Favourites: search for a note to add it, drag the rows to reorder, and
the top one opens with ⌘0, the next with ⌘1 and so on. The Favourites
menu lists them with their shortcuts. A note moved to the trash stops
being a favourite.

Renaming is the title field. Trashed notes are kept in the database with
a trashed date rather than deleted.

## Where the data lives

One SQLite store managed by SwiftData:

```
~/Library/Application Support/Notes.store
```

## Layout

```
Ugo/
  UgoApp.swift            entry point and scenes
  AppState.swift          selection, pane visibility, focus requests
  EditorLayout.swift      the open tabs, panes and columns, saved between launches
  AppCommands.swift       menu bar commands and shortcuts
  Theme.swift             the five themes and their colours
  Models/                 Folder and Note (@Model)
  Store/
    NotesStore.swift      the only place that touches SwiftData; hands views value snapshots
    StoreItems.swift      FolderItem, NoteItem, QuickOpenResult
    ObsidianConfig.swift  finds the open Obsidian vault for the first import
  Views/                  the sidebar, the editor grid with its tabs, quick open, welcome, settings
  Markdown/
    MarkdownHighlighter.swift   styling over NSMutableAttributedString, shared by both platforms
    MarkdownEditor.swift        NSTextView (macOS) and UITextView (iOS) wrappers
    ColumnBlocks.swift          finds `::: columns` blocks in the Markdown
    ColumnsOverlay.swift        lays a block's column text views over its hidden lines (macOS)
  Presentation/
    SlideDeck.swift       cuts a note into slides at its # and ## headings
    Presentation.swift    the full-screen slide window (macOS)
scripts/build.sh          swiftc build, no Xcode project needed
```

Typing goes to local view state and is written to SwiftData after a
500 ms pause, so keystrokes never wait on the database. Highlighting is
scoped to the paragraphs an edit or a cursor move touched.

## Bringing it to iPhone and iPad

The target already lists iOS as a supported platform and the sources
type-check against the iOS SDK. In Xcode, choose an iPhone simulator as
the destination and run. The app icon in `Assets.xcassets` already
carries the iOS 1024 px variant. Things to add when you get there:
tapping drawn checkboxes, and, for sync between devices, the iCloud
capability plus a CloudKit container in the target's Signing &
Capabilities tab. SwiftData picks it up from the entitlements.

Bundle identifier is `app.ugo`. It is only a name; no domain is needed
unless the app ships through the App Store.
