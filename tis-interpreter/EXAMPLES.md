The first example shows how to use the interpreter on a single file example.c.
From the directory examples/00_single_file, type:
../../tis-interpreter.sh example.c

The produced log should contain the following line, indicating that
an invalid pointer 'dest' is accessed at line 5:

example.c:5:[kernel] warning: out of bounds write. assert \valid(dest);

-----

Some C programs or libraries are spread over several files. In this case,
all the files must be provided at once on the command-line. For an example,
go to examples/01_multiple_files and type:
../../tis-interpreter.sh main.c concat.c

The produced log should contain the following line,

main.c:11:[value] warning: assert(match format and arguments), indicating that
the argument 'buffer' of printf does not match the %.*s format (reading from
buffer, one runs into uninitialized bytes before the terminating null character.

-----

When there is a main file with parameters, there is two choices: change the main
function of the source code, or simply give a stub which will call the main
with parameters you want. For an example, go to examples/02_keccak_sha_3, which
is a readable implementation of the sha3 cryptographic hash function
(downloaded from http://keccak.noekeon.org/readable_code.html ), and type:
../../tis-interpreter.sh -main tis_main tis-main.c readable_sha3/main.c \
                         readable_sha3/sha3.c

The analysis of libraries that depend on other libraries requires either to
provide replacement stubs for the called functions, or to list the source
code files of all libraries on the command-line at once. Providing single
pre-processing options that work for all source code files may get tricky.
You may want to pre-process each file according to its needs, and to provide
the names of the pre-processed files on the command-line instead.

-----

The next example, 03_filesystem/main.c, uses the functions fopen() and
fread() to access the filesystem. tis-interpreter provides an
implementation for a virtual filesystem so that this sort of program can
be run. To run this example, we are going to need:

- examples/03_filesystem/main.c: the program we are interested in running
- examples/03_filesystem/input.c: arbitrary contents for the file "input" in the
     virtual filesystem
- filesystem/*.c: the implementation for the functions fopen() and fread()

Use the command:

```
tis-interpreter$ ./tis-interpreter.sh --cc "-Ifilesystem"  examples/03_filesystem/*.c filesystem/*.c              
```

Once the execution per se starts, you should see:

```
17 bytes read:


97


115


100


102
...
```