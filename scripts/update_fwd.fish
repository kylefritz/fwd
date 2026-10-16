function update_fwd --description 'Build fwd on the dev box and install it on this laptop'
    # Install on the laptop with:
    #   scp mbar:code/fwd/scripts/update_fwd.fish ~/.config/fish/functions/
    set -l host mbar
    set -l repo code/fwd
    set -l app /Applications/fwd.app

    echo "→ building on $host"
    ssh $host "cd $repo && make app" | tail -1
    or begin
        echo "build failed on $host" >&2
        return 1
    end

    set -l tmp (mktemp -d)
    echo "→ copying fwd.zip"
    scp -q $host:$repo/build/fwd.zip $tmp/fwd.zip
    and ditto -x -k $tmp/fwd.zip $tmp/unpacked
    or begin
        echo "download or unzip failed; leaving the installed app alone" >&2
        return 1
    end

    # What's about to be installed: the version, and the commit it was built
    # from (`-dirty` if there were uncommitted changes on the dev box).
    set -l plist $tmp/unpacked/fwd.app/Contents/Info.plist
    set -l ver (plutil -extract CFBundleShortVersionString raw $plist 2>/dev/null; or echo unknown)
    set -l commit (plutil -extract FwdCommit raw $plist 2>/dev/null)
    set -l built $ver
    test -n "$commit"; and set built "$ver · $commit"
    set -l was (plutil -extract FwdCommit raw $app/Contents/Info.plist 2>/dev/null)
    test -z "$was"; and set was (plutil -extract CFBundleShortVersionString raw $app/Contents/Info.plist 2>/dev/null)
    if test -n "$was"
        echo "→ built fwd $built (installed: $was)"
    else
        echo "→ built fwd $built"
    end

    if pgrep -xq fwd
        echo "→ quitting fwd"
        # A normal quit, so fwd closes its ssh connections itself.
        osascript -e 'quit app "fwd"'
        for i in (seq 50)
            pgrep -xq fwd; or break
            sleep 0.2
        end
        if pgrep -xq fwd
            echo "fwd didn't quit; quit it from the menu bar and run update_fwd again" >&2
            return 1
        end
    end

    echo "→ installing to $app"
    if test -e $app
        trash $app
    end
    mv $tmp/unpacked/fwd.app $app
    and open -a $app
    and echo "✓ fwd $built installed and running"
end
