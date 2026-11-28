#!/bin/bash
# 稳定性验收：
#   1) 连续 10 万行输出不崩、内存峰值受限、最后一行确实画出（dump 断言）；
#   2) 空闲 CPU ≈ 0%（5 秒采样，阈值 2%）；
#   3) 空闲 8 秒内存不持续增长（阈值 +8 MB）。
# shellcheck source=scripts/e2e/win/lib.sh
. "$(dirname "$0")/lib.sh"

S="$WORK/stab"
mkdir -p "$(unixpath "$S")"

echo "== 10 万行输出 =="
start_instance stab100k -e 'cmd.exe /c for /l %i in (1,1,100000) do @echo L%i'
pid=$(instance_pid stab100k)
[ -z "$pid" ] && {
  echo "FAIL 100k: 实例没起来"
  FAIL=$((FAIL + 1))
}
peak=0
for _ in $(seq 1 240); do
  read -r _ ws <<<"$(sample_instance stab100k)"
  [ -z "$ws" ] && break
  [ "$ws" = "0" ] && break
  peak=$(python -c "print(max($peak, $ws))")
  sleep 0.5
done
assert_grep "100k 最后一行" "^L100000" "$(dump_file stab100k)"
assert_eq "100k 峰值内存 <200MB" "1" "$(python -c "print(1 if $peak < 200 else 0)")"
echo "峰值工作集: ${peak} MB"
stop_instance stab100k

echo "== 空闲 CPU =="
start_instance stabidle -e 'cmd.exe /k'
sleep 3
read -r cpu1 ws1 <<<"$(sample_instance stabidle)"
sleep 5
read -r cpu2 ws2 <<<"$(sample_instance stabidle)"
idle_pct=$(python -c "print(round(($cpu2-$cpu1)/5000*100, 2))")
echo "空闲 5 秒 CPU: ${idle_pct}% (工作集 ${ws2} MB)"
assert_eq "空闲 CPU <2%" "1" "$(python -c "print(1 if $idle_pct < 2 else 0)")"
assert_eq "空闲内存不增长 <8MB" "1" "$(python -c "print(1 if ($ws2-$ws1) < 8 else 0)")"
stop_instance stabidle

summary
