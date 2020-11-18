#!/usr/bin/env python3

from shutil import copyfile
import os

file = './pgl_ddl_deploy--2.0.sql'

old = file
new = f"{file}.new"

delete_ranges = [
    (62,146),
    (291,891),
    (975,1053),
    (1520,1587),
    (1746,1747),
    (1748,3009),
    (3012,3015),
    (3019,3655),
    (3673,3700),
    (3807,4563),
    (4681,4684),
    (4722,4723),
    (5138,5822),
    (5855,5865),
    (6008,6701),
]

n = 0
with open(old) as oldfile, open(new, 'w') as newfile:
    for line in oldfile:
        n += 1
        if any(lower <= n <= upper for (lower, upper) in delete_ranges):
            pass
        else:
            newfile.write(line)
copyfile(new, old)
