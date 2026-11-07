{ crontab -l 2>/dev/null | grep -v "# $N$" || true; echo "@reboot \"$D/run.sh\" # $N"; echo "* * * * * \"$D/run.sh\" # $N"; } | crontab -
