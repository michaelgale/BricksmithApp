# uncrustify --check -c uncrustify.cfg -F lintauto.txt 
# uncrustify --check -c uncrustify.cfg -l OC -F lintoc.txt 
uncrustify -c uncrustify.cfg --if-changed --replace --no-backup -F lintauto.txt 
uncrustify -c uncrustify.cfg --if-changed --replace --no-backup -l OC -F lintoc.txt 
