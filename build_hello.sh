zig build
mkdir -p examples/HelloWorld/apk/
zig-out/bin/craftdex dex examples/HelloWorld/HelloActivity.smali -o examples/HelloWorld/apk/classes.dex
~/.nimble/bin/marco -i=examples/HelloWorld/AndroidManifest.xml -o=examples/HelloWorld/apk/AndroidManifest.xml
basia -i=examples/HelloWorld/apk/ -o=examples/HelloWorld/hello.apk -c=key.x509.pem -k=key.pk8
