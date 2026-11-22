# The REPL

The REPL applet runs Janet, a Lisp. It scripts uniterm through the `uniterm` module, which every REPL imports before
the first prompt. See the [Janet documentation](https://janet-lang.org/docs/index.html) for the language itself.

## Inspecting the Environment

The REPL keeps your definitions in its own environment, and `(curenv)` returns it. Janet's core library sits behind
it as its prototype. Everything below is core Janet, and none of it needs a sandbox capability.

### Listing Bindings

List the symbols in your own environment:

```janet
(all-bindings (curenv) true)
```

The `true` keeps the list to the local environment. Without it, the list includes all of core.

The local list holds more than your own definitions. It includes the `uniterm/` functions, since the module is
imported into your environment. It also includes `_`, which holds the last result. Leave them out like this:

```janet
(filter |(not (or (= $ '_) (string/has-prefix? "uniterm/" $)))
        (all-bindings (curenv) true))
```

List only your functions:

```janet
(filter |(and (function? (eval $)) (not (string/has-prefix? "uniterm/" $)))
        (all-bindings (curenv) true))
```

List every function the `uniterm` module offers:

```janet
(filter |(string/has-prefix? "uniterm/" $) (all-bindings (curenv) true))
```

### Reading One Binding

Type a symbol to print its value. These forms say more about it:

| Form | Shows |
|---|---|
| `(doc greet)` | The docstring, the signature, and where it was defined. |
| `(type greet)` | The value's type, such as `:function` or `:table`. |
| `(get (curenv) 'x)` | The raw binding entry. |
| `(disasm greet)` | A function's bytecode. |

The raw entry differs by how the symbol was bound. A `def` stores its value under `:value`. A `var` stores it in a
one-element array under `:ref`, so a later `set` can change it:

```janet
repl:1:> (def x 42)
repl:2:> (var counter 0)
repl:3:> (get (curenv) 'x)
@{:source-map ("repl" 1 1) :value 42}
repl:4:> (get (curenv) 'counter)
@{:ref @[0] :source-map ("repl" 2 1)}
```

An entry also carries `:doc` when the definition has a docstring. Imported bindings carry `:private true`.

### The Last Result

`_` holds the result of the last form that finished. Type `_` to read it, or use it in the next form:

```janet
repl:1:> (+ 1 2)
3
repl:2:> (* _ 10)
30
```
