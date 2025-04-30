#!/bin/sh

MESA_VK_TRACE=rgp MESA_VK_TRACE_TRIGGER=/tmp/trigger zig build run
