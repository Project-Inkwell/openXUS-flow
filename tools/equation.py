"""An element's equation (`O6=(A1*(~A2))+...`, as Vivado states a LUT's)
as its truth table: entry k the value with input n at bit n-1 of k."""
import re


def truth_table(equation, inputs=None):
    _, expression = equation.split("=", 1)
    names = [int(n) for n in re.findall(r"[A-Za-z]+(\d+)", expression)]
    inputs = inputs or (max(names) if names else 0)
    python = re.sub(r"[A-Za-z]+(\d+)", lambda m: "x%s" % m.group(1), expression)
    python = python.replace("~", " not ").replace("*", " and ").replace("+", " or ").replace("@", " ^ ")
    code = compile(python, "<equation>", "eval")
    table = []
    for k in range(1 << inputs):
        scope = {"x%d" % n: bool((k >> (n - 1)) & 1) for n in range(1, inputs + 1)}
        table.append(bool(eval(code, {"__builtins__": {}}, scope)))
    return table
