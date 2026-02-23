

[@kosa12](https://x.com/kosa12) thx for the pull request but why did you disable shellcheck adding # shellcheck disable to many .sh files?

-   [![user avatar](https://pbs.twimg.com/profile_images/1967210808426782720/nGGLau9I_400x400.jpg)](https://x.com/kosa12)
    
    alex fazio
    
    ![attachment](blob:https://x.com/04149724-6298-436b-8bf3-048f65cfced4)
    
    @kosa12 thx for the pull request but why did you disable shellcheck
    
    cuz your pre commit shit was acting up
    
    14:07
    
    14:07
    
-   ksa 🏴☠️
    
    cuz i didnt wanted to rewrite the whole precommit check
    
-   [![user avatar](https://pbs.twimg.com/profile_images/1967210808426782720/nGGLau9I_400x400.jpg)](https://x.com/kosa12)
    
    but basically its low risk
    
    14:16
    
    14:16
    
-   ksa 🏴☠️
    
    i can try rewriting it, gimme 5 mins
    
-   [![user avatar](https://pbs.twimg.com/profile_images/1967210808426782720/nGGLau9I_400x400.jpg)](https://x.com/kosa12)
    
    cuz i think you havent used planktons precommit for plankton tho
    
    14:19
    
    14:19
    
    😂
    
-   ksa 🏴☠️
    
    [![user avatar](https://pbs.twimg.com/profile_images/1967210808426782720/nGGLau9I_400x400.jpg)](https://x.com/kosa12)
    
    done
    
    14:26
    
    14:26
    
-   ksa 🏴☠️
    
    [![user avatar](https://pbs.twimg.com/profile_images/1967210808426782720/nGGLau9I_400x400.jpg)](https://x.com/kosa12)
    
    now the precommit handles the exit codes safely
    
    14:35
    
    14:35
    
-   ksa 🏴☠️
    
    cuz your pre commit shit was acting up
    
    ok i'll have a look. i am working on a minor bugfix rn. when it's push i'll properly review your pr
    
    14:45
    
    14:45
    
-   ksa 🏴☠️
    
    [![user avatar](https://pbs.twimg.com/profile_images/1967210808426782720/nGGLau9I_400x400.jpg)](https://x.com/kosa12)
    
    thx
    
    14:46
    
    14:46
    
-   i need to put a ci that rejects pull request that add ignores to the files probably

-   you can do a baseline snapshot
    
    14:56
    
    14:56
    
    🤔
    
-   ![attachment](blob:https://x.com/c5ea52f5-8fae-4fcd-92a3-28772868cc7b)
    
    also this can be annoying but i think there's a solution
    
    14:56
    
    14:56
    
-   [![user avatar](https://pbs.twimg.com/profile_images/1967210808426782720/nGGLau9I_400x400.jpg)](https://x.com/kosa12)
    
    ksa 🏴☠️
    
    you can do a baseline snapshot
    
    for existing project. record the violations once, than fail only on new violations above baseline
    
    14:57
    
    14:57
    
-   ksa 🏴☠️
    
    for existing project. record the violations once, than fail only on new violations above baseline
    
    interesting. but some violations are like in context of the whole module. the baseline would basically have to add lint ignore comments to the whole codebase no?
    
-   meaning find the lines of codes with violations, identify the vilations, add the appropriate comment to that line
    
    14:58
    
    14:58
    
-   ksa 🏴☠️
    
    [![user avatar](https://pbs.twimg.com/profile_images/1967210808426782720/nGGLau9I_400x400.jpg)](https://x.com/kosa12)
    
    nah, that wouldnt be good, you can store them in a separate artifct with tuples (rule + file + message/context) and not inline the ignores, and on each run compare it with the baseline, if the fingerpint matches, its a legacy debt, if not "fix it retard". you can also add an expiry to baseline entries, so they dont became permanent, like for critical errors, you have 1 week before it starts blocking
    
    15:01
    
    15:01
    
    🔥
    
-   i'll put this in the roadmap
    
    15:05

why not just use git diffs
yea, thats how it would identify new changes, but you need a baseline for module or global rules
15:18
15

yea, thats how it would identify new changes, but you need a baseline for module or global rules
cuz lets say you have an unreachable function, you change something in it, with diff only, you run the checks, evrything works fine, even tho the function is still unreachable, so you need a basline for the snapshot, that has the project as the context
15:23

ea, thats how it would identify new changes, but you need a baseline for module or global rules
15:18
15:18
litu
user avatar
attachment
user avatar
ksa 🏴‍☠️
yea, thats how it would identify new changes, but you need a baseline for module or global rules
cuz lets say you have an unreachable function, you change something in it, with diff only, you run the checks, evrything works fine, even tho the function is still unreachable, so you need a basline for the snapshot, that has the project as the context
15:23
15:23
Today
New
Misu
user avatar
well the baseline is the remote
16:13
16:13
ksa 🏴‍☠️
cuz lets say you have an unreachable function, you change something in it, with diff only, you run the checks, evrything works fine, even th
though yeah i can see why using git diffs to ignore untouched code might not be the best in the case of unused functions for example

