#!/bin/sh

etags `find $PWD/src -name '*.lisp' -o -name '*.c' -o -name '*.h'`
