#!/bin/bash
# Test file with intentional ShellCheck violations for root cause investigation
# Each line triggers at least one ShellCheck finding

# SC2086: Double quote to prevent globbing and word splitting
echo $HOME
echo $USER
echo $PATH
echo $SHELL
echo $TERM

# SC2046: Quote this to prevent word splitting
files=$(ls /tmp)
echo $files

# SC2006: Use $(...) notation instead of legacy backticked `...`
today=`date +%Y-%m-%d`

# SC2034: Variable appears unused
unused_var="hello"

# SC2035: Use ./*glob* or -- *glob* so names with dashes won't be treated as options
cd /tmp && rm *.log

# SC2012: Use find instead of ls to better handle non-alphanumeric filenames
count=$(ls /tmp | wc -l)
echo $count
