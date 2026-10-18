"""使用 Python 标准库生成精确数值及日期转换的独立回归样例。"""
import argparse
import calendar
import datetime
import json
from pathlib import Path
import random
import re
import uuid

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "types" / "conversion_reference_test.mbt"


def date_text(days):
    # 独立按闰日计数并二分年份，不复用驱动的 400 年周期反算公式。
    def jan1(year):
        return 365 * (year - 1970) + calendar.leapdays(1970, year)
    low, high = -1000000000, 1000000001
    while low + 1 < high:
        middle = (low + high) // 2
        if jan1(middle) <= days:
            low = middle
        else:
            high = middle
    year = low
    rest = days - jan1(year)
    month = 1
    while rest >= calendar.monthrange(year, month)[1]:
        rest -= calendar.monthrange(year, month)[1]
        month += 1
    day = rest + 1
    if 0 <= year <= 9999:
        prefix = f"{year:04}"
    else:
        prefix = ("-" if year < 0 else "+") + f"{abs(year):06}"
    result = f"{prefix}-{month:02}-{day:02}"
    if 1 <= year <= 9999:
        assert result == (datetime.date(1970, 1, 1) + datetime.timedelta(days=days)).isoformat()
    return result


def time_text(nanos):
    seconds, fraction = divmod(nanos, 10**9)
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    return f"{hours:02}:{minutes:02}:{seconds:02}" + (f".{fraction:09}" if fraction else "")


def signed_bytes(value):
    width = max(1, ((value if value >= 0 else ~value).bit_length() + 8) // 8)
    return value.to_bytes(width, "big", signed=True)


def mb_bytes(value):
    return 'b"' + ''.join(f'\\x{byte:02x}' for byte in value) + '"'


def generate():
    rng = random.Random(2026101817)
    blocks = ['// 本文件由 scripts/conversion_reference.py 生成；使用 Python int、calendar、uuid 独立核对。\n']
    dates = [-2**31, 2**31-1, 0, -1, 11016, -719528, -719529]
    dates += [rng.randint(-2**31, 2**31-1) for _ in range(128)]
    blocks.append('///|\ntest "Python proleptic Gregorian date reference" {\n')
    for days in dates:
        text = json.dumps(date_text(days))
        blocks.append(f'  assert_eq(@types.CqlDate::from_days({days}).to_string(), {text})\n  assert_eq(@types.CqlDate::from_string({text}).days(), {days})\n')
    blocks.append('}\n\n///|\ntest "Python exact timestamp and nanosecond reference" {\n')
    timestamps = [-2**63, 2**63-1, 0, -1, 1, 9007199254740993, -9007199254740993]
    timestamps += [rng.randint(-2**63, 2**63-1) for _ in range(128)]
    for value in timestamps:
        days, millis = divmod(value, 86400000)
        text = json.dumps(date_text(days) + 'T' + time_text(millis * 10**6) + 'Z')
        blocks.append(f'  assert_eq(@types.CqlTimestamp::from_millis({value}L).to_string(), {text})\n  assert_eq(@types.CqlTimestamp::from_string({text}).millis(), {value}L)\n')
    for value in [0, 1, 86399999999999] + [rng.randrange(86400000000000) for _ in range(64)]:
        text = json.dumps(time_text(value))
        blocks.append(f'  assert_eq(@types.CqlTime::from_nanos({value}L).to_string(), {text})\n  assert_eq(@types.CqlTime::from_string({text}).nanos(), {value}L)\n')
    blocks.append('}\n\n///|\ntest "Python arbitrary precision signed integer reference" {\n')
    values = [0, 1, -1, 127, 128, -128, -129, 255, 256, -256, 2**63, -(2**63)-1]
    for bits in [8, 32, 64, 128, 256, 1024, 4096]:
        values += [rng.getrandbits(bits) * rng.choice([-1, 1]) for _ in range(8)]
    for value in values:
        payload = mb_bytes(signed_bytes(value))
        text = json.dumps(str(value))
        blocks.append(f'  assert_eq(@types.CqlVarInt::from_decimal_string({text}).to_bytes(), {payload})\n  assert_eq(@types.CqlVarInt::from_bytes({payload}).to_decimal_string(), {text})\n')
    blocks.append('}\n\n///|\ntest "Python UUID and decimal coefficient scale reference" {\n')
    for _ in range(32):
        value = uuid.UUID(int=rng.getrandbits(128))
        blocks.append(f'  assert_eq(@types.CqlUuid::from_string("{str(value).upper()}").to_bytes(), {mb_bytes(value.bytes)})\n  assert_eq(@types.CqlUuid::from_bytes({mb_bytes(value.bytes)}).to_string(), "{value}")\n')
    for index in range(48):
        coefficient = rng.getrandbits(200) * rng.choice([-1, 1])
        scale = rng.randint(-30, 90)
        scientific = str(coefficient) if scale == 0 else f'{coefficient}e{-scale}'
        digits = str(abs(coefficient))
        sign = '-' if coefficient < 0 else ''
        if scale <= 0:
            plain = sign + digits + '0' * -scale
        elif scale >= len(digits):
            plain = sign + '0.' + '0' * (scale - len(digits)) + digits
        else:
            plain = sign + digits[:-scale] + '.' + digits[-scale:]
        blocks.append(f'  let value_{index} = @types.CqlDecimal::from_parts({scale}, {mb_bytes(signed_bytes(coefficient))}); assert_eq(value_{index}.to_scientific_string(), "{scientific}"); assert_eq(value_{index}.to_plain_string(), "{plain}"); assert_eq(@types.CqlDecimal::from_string("{scientific}").to_value(), value_{index}.to_value()); assert_eq(@types.CqlDecimal::from_string("{plain}").to_plain_string(), "{plain}")\n')
    blocks.append('}\n')
    return ''.join(blocks)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    result = generate()
    if args.check:
        # 忽略格式化带来的空白、尾随逗号及分号，保留字符串及全部断言字符。
        def tokens(text):
            return re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|\s+|[,;]',
                          lambda match: match[0] if match[0].startswith('"') else '', text)
        if tokens(TARGET.read_text(encoding='utf-8')) != tokens(result):
            raise SystemExit('conversion reference differs; regenerate it')
        print('PASS Python exact conversion reference seed 2026101817')
    else:
        TARGET.write_text(result, encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
