# Third-party notices

MacMTP builds, dynamically links, and redistributes the following pinned source submodules in its packaged app bundle:

- [libmtp](https://github.com/libmtp/libmtp), GNU Lesser General Public License version 2 or later.
- [libusb](https://github.com/libusb/libusb), GNU Lesser General Public License version 2.1 or later.

Their dylibs are kept as separate files under each bundle's `Contents/Frameworks` directory and may be replaced with ABI-compatible builds. Their corresponding source code and license texts are included under `third_party/`; upstream build instructions are available from the linked projects. MacMTP's own LGPL 2.1 license text is included in [LICENSE](LICENSE).
