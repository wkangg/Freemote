# Freemote

A tweak that brings [BTTV](https://betterttv.com), [FFZ](https://www.frankerfacez.com) and [7TV](https://7tv.app)
emotes to the Twitch iOS app.

Originally written by [gilesgc](https://github.com/gilesgc/Freemote); this fork updates it for Twitch 31.x.

## Features

- BTTV, FFZ and 7TV emotes, global and per channel, in live chat, chat history and VOD chat
- Wide emotes at their own width, and 7TV zero-width emotes drawn over the emote before them
- Emote cards for external emotes, with the provider, uploader and a link to the emote's page
- Emotes show up as each provider loads, even on messages that came in first
- Deleted messages stay in chat, dimmed, instead of "message deleted by a moderator." (React Native stream screen)
- Channel points bonuses claimed as soon as they show up
- A Freemote page at the bottom of the account menu to turn each feature on or off

Works on both of Twitch's chat screens: the React Native one most streams open, and the native one vertical streams
still use.

## Install

Grab a build from [Actions](https://github.com/wkangg/Freemote/actions):

- **Jailbroken:** install the rootless or rootful `.deb`.
- **Sideloaded:** use a Freemote `.ipa`, then sign and install it with your usual tool.

To build an IPA yourself, run the `CI` workflow by hand with a direct link to a decrypted Twitch IPA:

```sh
gh workflow run build.yml -R wkangg/Freemote --ref master -f ipa_url=<decrypted IPA URL>
```

## Build

- The debs need [Theos](https://theos.dev).
- The IPA needs Theos and [theos-jailed](https://github.com/level3tjg/theos-jailed), which injects Freemote into a decrypted Twitch IPA.

```sh
# deb for rootful jailbreaks
make package

# deb for rootless jailbreaks
THEOS_PACKAGE_SCHEME=rootless make package

# Twitch IPA with Freemote injected, for sideloading (needs theos-jailed)
SIDELOADED=1 IPA=/path/to/decrypted/Twitch.ipa make package
```

## Logs

Freemote logs to the system log with a `[Freemote]` prefix. From a computer with the phone plugged in:

```sh
uvx --python 3.13 pymobiledevice3 syslog live -m "[Freemote]"
```

## License

[GPL-3.0](LICENSE)
