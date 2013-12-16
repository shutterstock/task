#!/bin/sh

echo "1..1"

if perl -c task ; then
  echo "ok 1 - fatpacked binary compiles"
  exit 0
else
  echo "not ok 1 - fatpacked binary compiles"
  exit 1
fi
