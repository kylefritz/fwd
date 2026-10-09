if command -v ss >/dev/null 2>&1; then echo "#ss"; ss -ltnH 2>/dev/null
elif command -v netstat >/dev/null 2>&1; then echo "#netstat"; netstat -an 2>/dev/null
elif command -v lsof >/dev/null 2>&1; then echo "#lsof"; lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null
else echo "#none"; fi
