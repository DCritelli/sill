# Sill

Sill shows one window from a Mac, or that Mac's whole desktop, on another device, and sends that device's input back to the Mac.

## Language

### Roles

**Host**:
The Mac whose windows are shown, running Sill for Mac.
_Avoid_: Server, companion, source Mac

**Device**:
Anything that connects to a Host to view and control it: an iPhone, an iPad, or a Mac running the Mac Client.
_Avoid_: Client (in prose), viewer, remote

**Mac Client**:
The Sill app that lets one Mac act as a Device for another Mac's Host.
_Avoid_: Mac viewer, desktop viewer, Sill Viewer

### What is shown

**Window**:
One top-level window of a Mac app on the Host. It is the unit Sill shows, never a whole app.
_Avoid_: App (when one window is meant), document

**Desktop**:
The Host's whole screen, shown as a single picture in place of a Window.

**Source**:
The one Window or the Desktop that the Host is showing right now.
_Avoid_: Stream target, selection

**Bar**:
The Device's row of live Window thumbnails and buttons, used to switch the Source one Window at a time.
_Avoid_: Dock, tab bar, switcher
