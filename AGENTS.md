# Agent instructions

## Formatting

`standardrb` must be run after every change:

```
bundle exec standardrb --fix
```

Any change that touches Ruby code is not finished until `bundle exec standardrb`
exits cleanly. The default Rake task (`bundle exec rake`) runs the test suite and
`standard` together, so it is a reasonable final check.
