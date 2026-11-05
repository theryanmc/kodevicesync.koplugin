# KODeviceSync for KOReader

Keep your KOReader plugins, user patches, fonts and style tweaks in a profile
on your own [KODeviceSync server](https://github.com/theryanmc/kodevicesync),
and set up any new e-reader to match in one tap.

- **Push:** pick what to sync on a device that's set up the way you like, and upload it to your profile.
- **Pull:** on a new device, download everything in your profile that's missing or out of date.
- **Built-ins are left alone:** plugins and fonts that come with KOReader are detected and never synced.
- **Never deletes anything** on a device.

You need a running KODeviceSync server. See the
[server repo](https://github.com/theryanmc/kodevicesync) for Docker and Unraid setup.

## Install

Choose one:

- **Storefront:** search for *KODeviceSync* and install it.
- **From a release:** download `kodevicesync.koplugin.zip` from the
  [latest release](https://github.com/theryanmc/kodevicesync.koplugin/releases/latest)
  and unzip it into KOReader's `plugins/` folder.
- **From your server:** download `http://<your-server>:1379/plugin.zip` and unzip it into `plugins/`.

The result should be `koreader/plugins/kodevicesync.koplugin/main.lua`.
Restart KOReader. The plugin is under **Tools (🔧) › KODeviceSync**.

## Use

1. Set **Server** to your server's address, e.g. `http://192.168.1.10:1379`, and **Log in**.
2. On your main device, open **Choose what to sync**, tick what you want (or turn on
   *Sync all* for a category), then **Push this device's setup to server**.
3. On a new device, tap **Pull setup from server**, then restart KOReader when it asks.

## What it syncs

| Category     | Folder in KOReader's data dir |
|--------------|-------------------------------|
| Plugins      | `plugins/*.koplugin`          |
| User patches | `patches/*.lua`               |
| Fonts        | `fonts/`                      |
| Style tweaks | `styletweaks/`                |

Plugin settings (`koreader/settings/`) are not synced.

## Releasing

Bump `version` in `_meta.lua`, commit, then tag and push:

```sh
git tag v1.0.1 && git push origin v1.0.1
```

The workflow attaches `kodevicesync.koplugin.zip` to the release.
