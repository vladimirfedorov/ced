ldc2 -unittest -i -Isrc src/ced/main.d -of=ced-test || exit 1
rm ced-test.o
./ced-test
