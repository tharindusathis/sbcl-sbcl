# Not a shell script, but something intended to be sourced from shell scripts
find_gnumake() {
  # the GNU dialect of "make" -- easier to find or port it than to
  # try to figure out how to port to the local dialect...
  if [ "$GNUMAKE" != "" ] ; then
    # The user is evidently trying to tell us something.
    GNUMAKE="$GNUMAKE"
  elif [ -x "`which gmake`" ] ; then
    # "gmake" is the preferred name in *BSD.
    GNUMAKE=gmake
  elif [ -x "`which gnumake`" ] ; then
    # MacOS X aka Darwin
    GNUMAKE=gnumake  
  elif [ "GNU Make" = "`make -v | head -n 1 | cut -b 0-8`" ]; then
    GNUMAKE=make
  else
    echo "GNU Make not found. Try setting the environment variable GNUMAKE."
    exit 1
  fi
  export GNUMAKE
  #echo "//GNUMAKE=\"$GNUMAKE\""
}
