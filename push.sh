#!/bin/bash
sas=$(date +%d%m%y)

cd /opt/banhammer &&\
git add . &&\
git commit -m "$sas autocommit"
git push -u origin main
echo "Done!"
