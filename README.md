# Shredders

The files in this repository are a stability and performance validation test
suite for memcached using https://github.com/memcached/mcshredder for load
generation.

This is used internally by the memcached project but published in the interest
of transparency. There is no support for these files.

This system largely what we used `mc-crusher` for in the past. All development
work is tested with this suite, often before it is even committed and
definitely before being put into a versioned release.
