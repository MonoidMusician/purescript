time=$(date)
echo 'module Main where

main = {a:""} {a="'$time'"}' > simple.purs
purs compile simple.purs
