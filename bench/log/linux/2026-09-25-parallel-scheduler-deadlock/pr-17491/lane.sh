n=$1; hs=0; hp=0
for i in $(seq $n); do
  timeout 20 ./ping-stock 2 4000 >/dev/null 2>&1; [ $? -eq 124 ] && hs=$((hs+1))
  timeout 20 ./ping-pr 2 4000 >/dev/null 2>&1; [ $? -eq 124 ] && hp=$((hp+1))
done
echo "$hs $hp"
