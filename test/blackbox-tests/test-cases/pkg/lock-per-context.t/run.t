Create a workspace with multiple contexts, each specifying a lockdir name.
  $ cat >dune-workspace <<EOF
  > (lang dune 3.8)
  > (lock_dir
  >  (path foo.lock)
  >  (repositories mock)
  >  (version_preference newest)) ; this is the default
  > (lock_dir
  >  (path prefers_oldest.lock)
  >  (repositories mock)
  >  (version_preference oldest))
  > (lock_dir
  >  (path bar.lock)
  >  (repositories mock))
  > (context
  >  (default
  >   (lock_dir foo.lock)))
  > (context
  >  (default
  >   (name foo)
  >   (lock_dir bar.lock)))
  > (context
  >  (default
  >   (name prefers_oldest)
  >   (lock_dir prefers_oldest.lock)))
  > (context
  >  (opam
  >   (name bar)
  >   (switch default)))
  > (repository
  >  (name mock)
  >  (source "file://$(pwd)/mock-opam-repository"))
  > EOF

Generate a `dune-project` file listing some dependencies.
  $ cat >dune-project <<EOF
  > (lang dune 3.8)
  > (package
  >  (name lockfile_generation_test)
  >  (depends
  >    foo
  >    (bar (>= "0.3"))
  >   ))
  > EOF

Test that we get an error when --context and --all-contexts are passed at the same time.
  $ dune pkg lock --all-contexts --context=foo
  Error: --context and --all-contexts are mutually exclusive
  [1]

Test that we get an error if a non-existant context is specified.
  $ dune pkg lock --context=baz
  Error: Unknown build context: baz
  [1]

Test that we get an error if an opam context is specified.
  $ dune pkg lock --context=bar
  Error: Unexpected opam build context: bar
  [1]

Generate the lockdir for the default context.
  $ dune pkg lock
  Solution for foo.lock:
  - bar.0.5.0
  - baz.0.1.0
  - foo.0.0.1

Only foo.lock (the default context's lockdir) was generated.
  $ find *.lock | sort
  foo.lock
  foo.lock/bar.pkg
  foo.lock/baz.pkg
  foo.lock/foo.pkg
  foo.lock/lock.dune
  $ rm -rf *.lock

Generate the lockdir with the default context explicitly specified.
  $ dune pkg lock --context=default
  Solution for foo.lock:
  - bar.0.5.0
  - baz.0.1.0
  - foo.0.0.1

Again, only foo.lock (the default context's lockdir) was generated.
  $ find *.lock | sort
  foo.lock
  foo.lock/bar.pkg
  foo.lock/baz.pkg
  foo.lock/foo.pkg
  foo.lock/lock.dune
  $ rm -rf *.lock

Generate the lockdir for the non-default context.
  $ dune pkg lock --context=foo
  Solution for bar.lock:
  - bar.0.5.0
  - baz.0.1.0
  - foo.0.0.1

Now only bar.lock was generated.
  $ find *.lock | sort
  bar.lock
  bar.lock/bar.pkg
  bar.lock/baz.pkg
  bar.lock/foo.pkg
  bar.lock/lock.dune
  $ rm -rf *.lock

Generate the lockdir for a context which prefers oldest package versions.
  $ dune pkg lock --context=prefers_oldest
  Solution for prefers_oldest.lock:
  - bar.0.4.0
  - baz.0.1.0
  - foo.0.0.1

Re-generate the lockdir for a context which prefers oldest package versions,
but override it to prefer newest with a command line argument.
  $ dune pkg lock --context=prefers_oldest --version-preference=newest
  Solution for prefers_oldest.lock:
  - bar.0.5.0
  - baz.0.1.0
  - foo.0.0.1

Generate the lockdir for all (non-opam) contexts.
  $ dune pkg lock --all-contexts
  Solution for prefers_oldest.lock:
  - bar.0.4.0
  - baz.0.1.0
  - foo.0.0.1
  Solution for bar.lock:
  - bar.0.5.0
  - baz.0.1.0
  - foo.0.0.1
  Solution for foo.lock:
  - bar.0.5.0
  - baz.0.1.0
  - foo.0.0.1

Now both lockdirs were generated.
  $ find *.lock | sort
  bar.lock
  bar.lock/bar.pkg
  bar.lock/baz.pkg
  bar.lock/foo.pkg
  bar.lock/lock.dune
  foo.lock
  foo.lock/bar.pkg
  foo.lock/baz.pkg
  foo.lock/foo.pkg
  foo.lock/lock.dune
  prefers_oldest.lock
  prefers_oldest.lock/bar.pkg
  prefers_oldest.lock/baz.pkg
  prefers_oldest.lock/foo.pkg
  prefers_oldest.lock/lock.dune
  $ rm -rf *.lock
