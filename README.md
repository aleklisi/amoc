# A Murder of Crows
[![](https://github.com/esl/amoc/workflows/CI/badge.svg)](https://github.com/esl/amoc/actions?query=workflow%3ACI)
[![Hex](http://img.shields.io/hexpm/v/amoc.svg)](https://hex.pm/packages/amoc)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/amoc/)

----------------------------------------------------------------------------------------------
A Murder of Crows, aka amoc, is a simple framework for running massively parallel tests in a distributed environment.

It can be used as a rebar3 dependency:

```erlang
{deps, [
    {amoc, "3.0.0-rc1"}
]}.
```
[MongooseIM](https://github.com/esl/MongooseIM) is continuously being load tested with Amoc.
All the XMPP scenarios can be found [here](https://github.com/esl/amoc-arsenal-xmpp).

---------------------------------------------------------------------
In order to implement and run locally your scenarios, follow the chapters about
[developing](guides/scenario.md) and [running](guides/local-run.md) a scenario
locally.
Before [setting up the distributed environment](guides/distributed.md),
please read through the configuration overview.

To see the full documentation, see [hexdocs](https://hexdocs.pm/amoc).
