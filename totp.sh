#!/bin/sh
set -euf +x

exec 3>&1 1>&2

LC_ALL=C
export LC_ALL

help() {
  printf '%s' 'totp -- Time-based One-time Password Generator

USAGE: totp [server] [interval] [timestamp] < secret

The default update interval is 30 seconds.
Timestamp is the seconds since 1970-01-01 00:00:00 UTC.

Supported servers: Google, GitHub, GitLab, Bitbucket
'
  exit 1
}
echo() {
  printf '%s\n' "$*"
}
ekho() {
  printf '[totp] %s\n\n' "$*"
}
have() {
  [ -x "$(command -v "$1" 2>/dev/null)" ]
}

hex_pack() {
  if have xxd; then
    xxd -p | tr -cd 0-9A-Fa-f
  else
    od -A n -t x1 -v | tr -cd 0-9A-Fa-f
  fi
}

hex_unpack() {
  if have xxd; then
    xxd -r -p
  else
    awk '
    function hex2num(hex, num,map,len,i,c)
    {
      map = "123456789ABCDEF"
      len = length(hex)
      num = 0
      for (i = 1; i <= len; i++) {
        c = toupper(substr(hex, i, 1))
        num = num * 16 + index(map, c)
      }
      return num
    }

    {
      gsub(/[^0-9A-Fa-f]+/, " ")  # split digits by non-digit
      gsub(/[0-9A-Fa-f]{2} */, "& ")  # group every two consecutive digits
      gsub(/^ +| [^ ] | +[^ ]?$/, "")  # trim spaces and single digit groups
      n = split($0, hh, " ")
      for (i = 1; i <= n; i++) printf "%c", hex2num(hh[i])
    }
    '
  fi
}

gen_digest() (
  set -e
  key="$1" period="$2"
  printf '%016X' "${period}" | hex_unpack | {
    # NUL is considered harmful. Avoid -hmac <binarykey>!
    nul="$(sed -n 's/../&_/g;/00_/p;/_0$/p' <<EOT
${key}
EOT
)"
    # FIXME: can we not put the key on argv?
    if [ '' != "${nul}" ]; then
      openssl dgst -sha1 -mac hmac -macopt "hexkey:${key}"
    else # especially for old versions from OSX/BSD!
      openssl dgst -sha1 -hmac "$(echo "${key}" | hex_unpack)"
    fi
  } | cut -d' ' -f2
)

# https://tools.ietf.org/html/rfc6238
gen_token() (
  set -e
  server="${1-Google}"
  interval="${2-30}"
  now="${3-$(date '+%s')}"

  if [ -t 0 ]; then
    echo "Enter your secret token: (Press Ctrl-D to Quit)"
  fi
  secret="$(cat)"

  err=''
  if [ '' = "${secret}" ]; then
    ekho 'The secret token was empty!'; err=1
  fi
  if [ 0 -ge "${interval}" ]; then
    ekho 'The interval could not be recognized as a positive integer!'; err=1
  fi
  if ! { [ 0 -le "${now}" ] || [ 0 -ge "${now}" ]; }; then
    ekho 'The timestamp could not be recognized as an integer!'; err=1
  fi
  if [ '' != "${err}" ]; then
    help
  fi

  server="$(echo "${server}" | tr A-Z a-z)"

  # remove whitespace and leading zeros (and number sign)
  interval="$(( ${interval#"${interval%%[1-9]*}"} + 0 ))"
  now="$(( ${now%%[0-9]*}${now#"${now%%[1-9]*}"} + 0 ))"

  period="$(( now / interval ))"

  case "${server}" in
    # https://github.com/google/google-authenticator/wiki/Key-Uri-Format
    (google|github|gitlab|bitbucket)
      key="$(printf '%s' $secret | base32 -d | hex_pack)"
      [ '' != "${key}" ] || exit 2
      # The digest is a 160-bit hexadecimal number string.
      digest="$(gen_digest "${key}" "${period}" | tr -cd 0-9A-Fa-f)"
      [ 40 -eq "${#digest}" ] || exit 3
      # Read the last 4 bits and convert it into an unsigned integer.
      offset="0x$(echo "${digest}" | cut -b 40)"
      offset="$(( offset * 2 + 1))"
      [ 33 -ge "${offset}" ] || exit 4
      # Read a 32-bit positive integer and take at most six rightmost digits.
      number="0x$(echo "${digest}" | cut -b "${offset}-$(( offset + 7 ))")"
      token="$(( (number & 0x7FFFFFFF) % 1000000 ))"
      # Pad the token number with leading zeros if needed.
      printf '%06d\n' "${token}" >&3
      ;;
    (*)
      ekho "Your server is not supported: ${server}"
      help
  esac
)

gen_token ${1+"$@"}