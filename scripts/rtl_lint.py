#!/usr/bin/env python3
"""
rtl_lint.py — статический анализ RTL через pyverilog (с fallback на regex).
Проверяет: парсинг, баланс скобок, парность begin/end, module/endmodule,
соответствие портов инстансов декларациям модулей.

Usage:
    python3 rtl_lint.py [directory]
"""
import os
import re
import sys
from pathlib import Path

# pyverilog может не понимать SV (always_ff, logic, $clog2 в параметрах)
# пробуем загрузить, но не падаем, если не вышло
PYVERILOG_AVAILABLE = False
try:
    sys.path.insert(0, '/home/z/.local/lib/python3.13/site-packages')
    import pyverilog.vparser.parser as vparser
    PYVERILOG_AVAILABLE = True
except Exception as e:
    print(f"# pyverilog не загружен: {e}", file=sys.stderr)


# ----- regex-based checks -----

def check_brackets(text: str) -> dict:
    """Баланс (), {}, [] с учётом строк и комментариев."""
    # удалить комментарии
    no_comments = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    no_comments = re.sub(r'//[^\n]*', '', no_comments)
    # удалить строки
    no_strings = re.sub(r'"(?:[^"\\]|\\.)*"', '""', no_comments)
    counts = {'paren': 0, 'brace': 0, 'bracket': 0}
    for ch in no_strings:
        if ch == '(': counts['paren'] += 1
        elif ch == ')': counts['paren'] -= 1
        elif ch == '{': counts['brace'] += 1
        elif ch == '}': counts['brace'] -= 1
        elif ch == '[': counts['bracket'] += 1
        elif ch == ']': counts['bracket'] -= 1
        if any(v < 0 for v in counts.values()):
            return {'ok': False, 'counts': counts, 'msg': 'negative balance (extra closing)'}
    ok = all(v == 0 for v in counts.values())
    return {'ok': ok, 'counts': counts,
            'msg': '' if ok else f'imbalance: {counts}'}


def check_begin_end(text: str) -> dict:
    """Парность begin/end."""
    no_comments = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    no_comments = re.sub(r'//[^\n]*', '', no_comments)
    # удалить строки
    no_strings = re.sub(r'"(?:[^"\\]|\\.)*"', '""', no_comments)
    begins = len(re.findall(r'\bbegin\b', no_strings))
    ends = len(re.findall(r'\bend\b', no_strings))
    # case ... endcase, module ... endmodule, etc. — отдельно
    case = len(re.findall(r'\bcase\b', no_strings)) - len(re.findall(r'\bendcase\b', no_strings))
    mod = len(re.findall(r'\bmodule\b', no_strings)) - len(re.findall(r'\bendmodule\b', no_strings))
    # begin/end для fork/join — пропускаем (нет в нашем коде)
    net = begins - ends
    return {'begins': begins, 'ends': ends, 'diff': net,
            'ok': net == 0, 'msg': '' if net == 0 else f'begin/end diff={net}'}


def check_modules(text: str) -> dict:
    """Парность module/endmodule."""
    mods = len(re.findall(r'^\s*module\s+\w+', text, flags=re.MULTILINE))
    endmods = len(re.findall(r'^\s*endmodule\b', text, flags=re.MULTILINE))
    return {'modules': mods, 'endmodules': endmods,
            'ok': mods == endmods, 'msg': '' if mods == endmods else f'mismatch module/endmodule: {mods}/{endmods}'}


def extract_module_ports(text: str) -> dict:
    """Извлечь порты модуля (имя, направление, ширина)."""
    # упрощённо — ищем module X #( ... ) ( ... );
    m = re.search(r'module\s+(\w+)\s*(?:#\s*\((.*?)\))?\s*\(([^;]*)\)\s*;', text, flags=re.DOTALL)
    if not m:
        return {}
    mod_name = m.group(1)
    ports_str = m.group(3)
    ports = []
    # парсим порты — упрощённо
    # каждый порт: input/output/inout [width] name
    pat = re.compile(
        r'(input|output|inout)\s+(?:logic\s+|wire\s+|reg\s+)?(?:\[\s*(\d+)\s*:\s*(\d+)\s*\]\s+)?(\w+)',
        re.MULTILINE
    )
    for mm in pat.finditer(ports_str):
        direction = mm.group(1)
        msb = int(mm.group(2)) if mm.group(2) else 0
        lsb = int(mm.group(3)) if mm.group(3) else 0
        width = abs(msb - lsb) + 1
        name = mm.group(4)
        ports.append({'name': name, 'dir': direction, 'width': width})
    return {mod_name: ports}


def extract_instance_ports(text: str) -> list:
    """Извлечь инстансы: ModuleName u_inst ( .Port(signal), ... );"""
    instances = []
    # упрощённо: <ModName> <inst_name> #( ... ) ( ... );
    pat = re.compile(
        r'(\w+)\s+(\w+)\s*(?:#\s*\([^)]*\))?\s*\(([^;]*)\)\s*;',
        re.DOTALL
    )
    for m in pat.finditer(text):
        mod_name = m.group(1)
        inst_name = m.group(2)
        conns_str = m.group(3)
        # пропускаем, если это не инстанс (например, module declaration)
        if mod_name in ('module', 'always_ff', 'always_comb', 'always', 'initial', 'assign', 'if', 'for', 'case'):
            continue
        conns = []
        for cm in re.finditer(r'\.(\w+)\s*\(([^,)]*)\)', conns_str):
            conns.append({'port': cm.group(1), 'signal': cm.group(2).strip()})
        if conns:
            instances.append({'module': mod_name, 'instance': inst_name, 'conns': conns})
    return instances


def analyze_file(path: Path) -> dict:
    """Полный анализ одного файла."""
    try:
        text = path.read_text(encoding='utf-8', errors='replace')
    except Exception as e:
        return {'file': str(path), 'error': f'read: {e}'}

    result = {
        'file': str(path),
        'lines': text.count('\n') + 1,
        'brackets': check_brackets(text),
        'begin_end': check_begin_end(text),
        'modules': check_modules(text),
        'module_ports': extract_module_ports(text),
        'instances': extract_instance_ports(text),
    }

    # pyverilog try
    if PYVERILOG_AVAILABLE:
        try:
            # препроцесс: заменить SV-конструкции на Verilog-2001
            pre = text
            pre = re.sub(r'\balways_ff\b', 'always', pre)
            pre = re.sub(r'\balways_comb\b', 'always @*', pre)
            pre = re.sub(r'\balways_latch\b', 'always', pre)
            # 'logic' в порт-декларациях -> убрать (input logic -> input)
            # 'logic' как тип переменной -> 'reg'
            pre = re.sub(r'\b(input|output|inout)\s+logic\b', r'\1', pre)
            pre = re.sub(r'\b(input|output|inout)\s+wire\b', r'\1', pre)
            pre = re.sub(r'\b(input|output|inout)\s+reg\b', r'\1', pre)
            pre = re.sub(r'\blogic\b', 'reg', pre)
            pre = re.sub(r'\bbit\b', 'reg', pre)
            pre = re.sub(r'\bbyte\b', 'reg [7:0]', pre)
            pre = re.sub(r'\bint\b', 'integer', pre)
            # $clog2 -> константа (мы не знаем значение, но 32 — достаточно для парсинга)
            pre = re.sub(r'\$clog2\(([^)]*)\)', r'32', pre)
            # $bits -> константа
            pre = re.sub(r'\$bits\(([^)]*)\)', r'32', pre)
            # package import
            pre = re.sub(r'^\s*import\s+\w+::\*;\s*$', '', pre, flags=re.MULTILINE)
            # ASYNC_REG и др. attributes
            pre = re.sub(r'\(\*\s*ASYNC_REG\s*=\s*"[^"]*"\s*\*\)', '', pre)
            pre = re.sub(r'\(\*\s*\w+\s*=\s*"[^"]*"\s*\*\)', '', pre)
            # package::type -> type (упрощённо)
            pre = re.sub(r'\btfloat_pkg::(\w+)\b', r'\1', pre)
            # typedef в начале модуля — удалить (pyverilog не понимает)
            pre = re.sub(r'^\s*typedef\s+.*?;\s*$', '', pre, flags=re.MULTILINE)
            # enum -> reg [31:0] (упрощённо)
            pre = re.sub(r'\benum\s*\{[^}]*\}\s*\w+\s*;', 'reg [31:0] enum_placeholder;', pre)
            # struct -> reg [31:0]
            pre = re.sub(r'\bstruct\s*\{[^}]*\}\s*\w+\s*;', 'reg [31:0] struct_placeholder;', pre, flags=re.DOTALL)
            # unique case / priority case -> case
            pre = re.sub(r'\bunique\s+case\b', 'case', pre)
            pre = re.sub(r'\bpriority\s+case\b', 'case', pre)
            # 'static'/'automatic' lifetime qualifiers
            pre = re.sub(r'\b(static|automatic)\s+', '', pre)
            # записать во временный файл
            tmp = path.with_suffix('.v.lint_tmp')
            tmp.write_text(pre)
            try:
                ast, directives = vparser.parse([str(tmp)])
                result['pyverilog'] = 'OK'
            finally:
                tmp.unlink(missing_ok=True)
        except Exception as e:
            result['pyverilog'] = f'FAIL: {type(e).__name__}: {str(e)[:200]}'
    else:
        result['pyverilog'] = 'skipped (not installed)'

    return result


def main():
    if len(sys.argv) > 1:
        dirs = [sys.argv[1]]
    else:
        dirs = [
            '/home/z/my-project/repo/main/rtl/integration',
            '/home/z/my-project/repo/main/rtl/block',
            '/home/z/my-project/repo/main/rtl/rtl',
        ]

    print(f"# RTL lint report")
    print(f"# pyverilog: {'available' if PYVERILOG_AVAILABLE else 'NOT available'}")
    print()

    all_results = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for ext in ('*.sv', '*.v'):
            for path in sorted(Path(d).glob(ext)):
                r = analyze_file(path)
                all_results.append(r)

    # print summary
    print(f"{'FILE':<60} {'LINES':>6} {'BRK':>4} {'B/E':>5} {'MOD':>5} {'PYV':>10}")
    print('-' * 100)
    for r in all_results:
        if 'error' in r:
            print(f"{r['file']:<60} ERROR: {r['error']}")
            continue
        fname = r['file'].replace('/home/z/my-project/repo/main/', '')
        brackets = 'OK' if r['brackets']['ok'] else 'FAIL'
        begin_end = 'OK' if r['begin_end']['ok'] else f"diff={r['begin_end']['diff']}"
        modules = 'OK' if r['modules']['ok'] else f"{r['modules']['modules']}/{r['modules']['endmodules']}"
        pyv = r['pyverilog'][:10] if isinstance(r['pyverilog'], str) else 'OK'
        print(f"{fname:<60} {r['lines']:>6} {brackets:>4} {begin_end:>5} {modules:>5} {pyv:>10}")

    # details for failures
    print()
    print('# DETAIL FAILED FILES:')
    for r in all_results:
        if 'error' in r:
            continue
        problems = []
        if not r['brackets']['ok']:
            problems.append(f"brackets: {r['brackets']['msg']}")
        if not r['begin_end']['ok']:
            problems.append(f"begin/end: {r['begin_end']['msg']}")
        if not r['modules']['ok']:
            problems.append(f"modules: {r['modules']['msg']}")
        if isinstance(r['pyverilog'], str) and r['pyverilog'].startswith('FAIL'):
            problems.append(f"pyverilog: {r['pyverilog']}")
        if problems:
            print(f"\n## {r['file']}")
            for p in problems:
                print(f"  - {p}")

    # module port cross-check
    print()
    print('# MODULE PORT CROSS-CHECK:')
    # собрать все декларации модулей со всех файлов
    all_modules = {}
    for r in all_results:
        for mod_name, ports in r['module_ports'].items():
            all_modules[mod_name] = {'ports': ports, 'file': r['file']}
    # для каждого инстанса проверить, что все порты подключены
    for r in all_results:
        for inst in r['instances']:
            mod = inst['module']
            if mod not in all_modules:
                continue  # модуль не в нашей выборке
            declared = {p['name'] for p in all_modules[mod]['ports']}
            connected = {c['port'] for c in inst['conns']}
            missing = declared - connected
            extra = connected - declared
            if missing or extra:
                print(f"  INST {inst['instance']} ({mod}) in {r['file']}:")
                if missing:
                    print(f"    MISSING: {missing}")
                if extra:
                    print(f"    EXTRA:   {extra}")


if __name__ == '__main__':
    main()
