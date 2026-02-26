#!/usr/bin/env sh
exec swift format format \
  --parallel \
  --recursive \
  --in-place \
  . "$@"
