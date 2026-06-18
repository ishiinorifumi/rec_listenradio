#!/usr/bin/env bash
#
# rec_listenradio.sh - ListenRadio（リスラジ）録音スクリプト
#
# License: MIT (c) 2026 ISHII Norifumi
# 本スクリプト及び本ツールは、ListenRadio とそのサービス及び
# 株式会社ディーピーエヌとは一切関係がありません。
#
# 必要なもの:
#   - ffmpeg（必須。環境変数 FFMPEG で実行パスを上書き可。例: vendor/ffmpeg.exe）
#   - curl, jq（任意。あれば局名を取得してタグ／ファイル名に使う）
#
# 例:
#   ./rec_listenradio.sh -c 30011 -d 30
#   ./rec_listenradio.sh -c 30011 -d 60 -f mp3 -b 256 -o radio.mp3
#   ./rec_listenradio.sh -c 30011 -d 01:00:00 -f m4a -b copy

set -eu

readonly ORIGIN="https://listenradio.jp"
readonly STREAM_FMT="https://mtist.as.smartstream.ne.jp/%s/livestream/playlist.m3u8"
readonly SCHEDULE_FMT="https://listenradio.jp/service/schedule.aspx?channelid=%s"
readonly CHANNELLIST_URL="https://listenradio.jp/service/channellist.aspx?categoryid=10005&offset=0&count=999"
readonly UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

FFMPEG="${FFMPEG:-ffmpeg}"

usage() {
  cat <<'EOS'
使い方: rec_listenradio.sh -c <チャンネルID> -d <録音時間> [オプション]
       rec_listenradio.sh -l            （局リストを表示して終了）

必須:
  -c <id>        リスラジのチャンネルID（例: 30011）
  -d <時間>      録音時間。数値だけなら「分」（例: 30）、
                 ":" を含めば HH:MM:SS（例: 01:30:00）

任意:
  -f <mp3|m4a>   出力形式（既定: mp3）
  -b <bitrate>   音声ビットレート kbps（既定: 128）。
                 m4a のときだけ "copy" を指定すると再エンコードせず
                 元の AAC をそのまま保存（最高音質・-b の数値は無視）
  -o <file>      出力ファイル名（既定: <局名>_<日時>.<拡張子>）
  -l             局リスト（エリア別の「ID 局名」）を表示して終了
  -n             ドライラン（実行する ffmpeg コマンドを表示するだけ）
  -h             このヘルプを表示

例:
  rec_listenradio.sh -c 30011 -d 30
  rec_listenradio.sh -c 30011 -d 60 -f mp3 -b 256 -o radio.mp3
  rec_listenradio.sh -c 30011 -d 01:00:00 -f m4a -b copy
EOS
}

# 局リスト（エリア別の「ID 局名」）を取得して表示する。
list_channels() {
  command -v curl >/dev/null 2>&1 || { echo "エラー: 局リスト取得には curl が必要です。" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "エラー: 局リスト取得には jq が必要です。" >&2; exit 1; }
  local json
  json=$(curl -fsS -A "$UA" -e "$ORIGIN/" "$CHANNELLIST_URL" 2>/dev/null || true)
  [ -n "$json" ] || { echo "エラー: 局リストの取得に失敗しました（地域制限/通信不可の可能性）。" >&2; exit 1; }
  printf '%s' "$json" | jq -r '
    .Area[]
    | "[\(.AreaName)]", (.Channel[] | "  \(.ChannelId)\t\(.ChannelName)")
  '
}

# ---- 既定値 ----
fmt="mp3"
bitrate="128"
channel=""
duration=""
output=""
dryrun=0
listmode=0

while getopts "c:d:f:b:o:lnh" opt; do
  case "$opt" in
    c) channel="$OPTARG" ;;
    d) duration="$OPTARG" ;;
    f) fmt="$OPTARG" ;;
    b) bitrate="$OPTARG" ;;
    o) output="$OPTARG" ;;
    l) listmode=1 ;;
    n) dryrun=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# 局リスト表示モード（-c/-d 不要）
if [ "$listmode" -eq 1 ]; then
  list_channels
  exit 0
fi

# ---- 入力チェック ----
if [ -z "$channel" ] || [ -z "$duration" ]; then
  echo "エラー: -c（チャンネルID）と -d（録音時間）は必須です。" >&2
  usage
  exit 1
fi
case "$fmt" in
  mp3 | m4a) ;;
  *) echo "エラー: -f は mp3 か m4a を指定してください（指定: $fmt）。" >&2; exit 1 ;;
esac
if [ "$bitrate" = "copy" ] && [ "$fmt" != "m4a" ]; then
  echo "エラー: -b copy は -f m4a のときだけ使えます。" >&2
  exit 1
fi
if [ "$dryrun" -eq 0 ] && ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "エラー: ffmpeg が見つかりません（環境変数 FFMPEG で指定可）。" >&2
  exit 1
fi

# ---- 録音時間を ffmpeg の -t 形式へ変換 ----
# ":" を含めば HH:MM:SS としてそのまま、数値だけなら「分」→秒に換算。
if printf '%s' "$duration" | grep -q ':'; then
  t_arg="$duration"
elif printf '%s' "$duration" | grep -Eq '^[0-9]+$'; then
  t_arg=$((duration * 60))
else
  echo "エラー: -d は分（数値）か HH:MM:SS で指定してください（指定: $duration）。" >&2
  exit 1
fi

# ---- 局名の取得（curl と jq があれば。失敗しても続行）----
station=""
program=""
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  sched_url=$(printf "$SCHEDULE_FMT" "$channel")
  now=$(date +%Y%m%d%H%M)
  json=$(curl -fsS -A "$UA" -e "$ORIGIN/" "$sched_url" 2>/dev/null || true)
  if [ -n "$json" ]; then
    station=$(printf '%s' "$json" | jq -r '.ProgramSchedule[0].StationName // empty' 2>/dev/null || true)
    # StartDate/EndDate は "YYYYMMDDHHMM"。同じ桁数なので文字列比較で現在番組を判定。
    program=$(printf '%s' "$json" | jq -r --arg now "$now" \
      'first(.ProgramSchedule[] | select(.StartDate <= $now and $now < .EndDate) | .ProgramName) // empty' \
      2>/dev/null || true)
  fi
fi
[ -z "$station" ] && station="ch${channel}"

# ---- 出力ファイル名（未指定なら自動生成）----
sanitize() { printf '%s' "$1" | tr '\\/:*?"<>|' '_________' | tr -d '\r\n'; }
if [ -z "$output" ]; then
  ts=$(date +%Y%m%d-%H%M)
  output="$(sanitize "$station")_${ts}.${fmt}"
fi

# ---- エンコード設定 ----
stream_url=$(printf "$STREAM_FMT" "$channel")
# $() は末尾改行を削るため、CRLF はリテラル連結で付ける（ffmpeg は各ヘッダを CRLF 終端で受け取る）
hdr="Origin: ${ORIGIN}"$'\r\n'

codec_args=()
case "$fmt" in
  mp3)
    codec_args=(-acodec libmp3lame -b:a "${bitrate}k" -id3v2_version 3)
    ;;
  m4a)
    if [ "$bitrate" = "copy" ]; then
      # HLS(ADTS) の AAC をそのまま m4a へ。ADTS→MP4 変換に bsf が必要。
      codec_args=(-acodec copy -bsf:a aac_adtstoasc)
    else
      codec_args=(-acodec aac -b:a "${bitrate}k")
    fi
    ;;
esac

meta_args=(-metadata "artist=${station}" -metadata "date=$(date +%Y-%m-%d)")
[ -n "$program" ] && meta_args+=(-metadata "title=${program}")

cmd=(
  "$FFMPEG" -hide_banner -loglevel warning
  -headers "$hdr"
  -i "$stream_url"
  -t "$t_arg"
  -vn "${codec_args[@]}"
  "${meta_args[@]}"
  -y "$output"
)

if [ "$dryrun" -eq 1 ]; then
  printf '%q ' "${cmd[@]}"
  echo
  exit 0
fi

echo "録音開始: 局=${station} 形式=${fmt} ビットレート=${bitrate} 時間=${t_arg} → ${output}"
"${cmd[@]}"
echo "録音完了: ${output}"
