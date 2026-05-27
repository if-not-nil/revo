# doc

the best way to document your code is proper function naming, parameter naming, and typing.
but that's not enough, so for that - we have `@doc`

## usage

`@doc` goes there. the doc text can be any string (`'adsf'`, `"asdf"`, `\`asdf\``)

```ruby
@doc "adds two numbers"
fn add(a, b) a + b
```

```ruby
@doc """
adds two numbers
and returns the result
"""
fn add(a, b) a + b
```

it works on all function declaration forms:

```ruby
@doc "named function"
fn greet(name) "hi " + name

@doc "anon assigned to const"
const shout = fn(name) name:upper()

@doc "method-style"
fn math:twice(x) x * 2
```

## extraction

docs are extracted statically from the ast:

```
revo --docs script.rv
```

output format shows name, arity, and doc text:

```
# docs for script.rv

- add/2
adds two numbers

- greet/1
named function
```
