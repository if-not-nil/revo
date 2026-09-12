# revo docs

there are the ones that show up on the web, verbatim
auto-synced

`std.html` is template-only, to generate:

```bash
set STDOCPATH ./_ign-web/content/std.html
revo doc --html --splice ../src/std/iface < "$STDOCPATH" > ./std-finished.html
mv ./std-finished.html $STDOCPATH
```
