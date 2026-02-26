#!/usr/bin/env sh
exec swift format lint \
  --parallel \
  --recursive \
  --strict \
  . "$@"
