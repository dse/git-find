-   This program should be called `gitfind` as `git-find` would be
    something you run *within* a git repository.

-   use case:

        find ... -exec git ab \; -exec git push \;

-   in terms of find:

        find ... -type d \! \( -name node_modules -prune \) \
                         \! \( -name vendor -exec test -e {}/composer.json \; -prune \) \
                         -exec test -d {}/.git 
