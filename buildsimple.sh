time=$(date)
echo 'module Main where

main = {a:""} {a="'$time'"}' > simple.purs
stack exec purs -- compile simple.purs
