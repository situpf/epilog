#!/bin/bash

# Variables de configuraciÃ ...

DEBUG=false  

# Si l'us de la memoria feta servir està  per sota d'aquest % avisem a l'usuari
MIN_MEM_USED=80

# Memoria mínima que ha de demanar l'usuari per que es faci aquest control en MB.
MIN_MEM=8192 # Mb

# Walltime mànim de un job per control·lar la memória feta servir (en segons)
MIN_WALLTIME=5 # Minutes 

# Temps mÃ xim d'espera si el job estÃ  encara en running en <segons>.<milisegons>
MAX_WAIT_TIME=2.00  # Seconds

# Labs to be checked (separats per un espai). Si ALL, all labs are going to be monitorized.
LABS_TO_CHECK="ALL"

# Programes
SEFF=/usr/bin/seff
MAIL=/usr/bin/mail

# Environment variables
EV_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EV_SLURM_CONF="/etc/slurm/slurm.conf"

# Fitxer de log 
LOGFILE=/var/log/slurm/epilog-mem-efficiency.log

# On guardem la info dels arrayjobs que estem control·lant
PATH_ARRAYJOBS=/etc/slurm/epilog/arrayjobs

# Fitxer que fem servir com a semÃ for
LOCK_FILE="/etc/slurm/epilog/arrayjobs.lock"

# Fitxer auxiliar per la generació del cos del mail
EMAILBODY=/tmp/epilog-mem-efficiency

# Adreça de mail dels técnics
IT_RECIPIENT="miguelangel.sanchez@upf.edu"
#IT_RECIPIENT="sit@upf.edu"

# LDAP SERVER
LDAP_SERVER="sit-ldap.s.upf.edu"
LDAP_BASEDN="dc=upf,dc=edu"

# I aquí­ comencem ...

# Per controlï¿½lar si es un array job
IS_ARRAY=false

# Miro si es un array job ja que llavors hem de fer una preparació extra del jobid
if [ ${SLURM_ARRAY_JOB_ID} ]; then
        JOBID=${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}
	IS_ARRAY=true
else
        JOBID=${SLURM_JOB_ID}
fi

# Mirem si el job es de uns dels labos que hem de control·lar. 
LABS_TO_CHECK=`echo "${LABS_TO_CHECK}" | sed "s/\s/|/g"`
if [[ ! "${SLURM_JOB_ACCOUNT}" =~ ^(${LABS_TO_CHECK})$ ]] && [ "${LABS_TO_CHECK}" != "ALL" ]; then
	# El job no pertany a un dels labos a monitoritzar.
	if [[ "${DEBUG}" == "true" ]]; then
 	       echo -e "\nJobID: ${JOBID} -> This job not belongs to one of the labs to be monitored: ${LABS_TO_CHECK}" >> ${LOGFILE}
	fi
	exit 0
fi

# Només mirem els jobs que han acabat bé (status=COMPLETED)
if [ ${SLURM_JOB_EXIT_CODE} -ne "0" ]; then
	if [[ "${DEBUG}" == "true" ]]; then
 		echo -e "\nJobID: ${JOBID} -> The job exit code hasn't been 0 (${SLURM_JOB_EXIT_CODE})" >> ${LOGFILE}
	fi
	exit 0
fi

# Definim l'entorn 
export PATH=${EV_PATH}
export SLURM_CONF=${EV_SLURM_CONF}

# Agafem el consum del job fent servir la comanda auxiliar 'seff' del slurm
SEFF_OUTPUT=`${SEFF} -d ${JOBID}`

# Vam detectar que amb alguns jobs, quan s'executa el epilog el job encara no ha acabat del tot. Poder es degut
# a que el I/O estar  anant lent, que la BBDD del accounting està molt carregada i l'escriptura del accounting est+a
# en waiting, etc. Si veiem que el job està  en aquest estat no fem res.

JOB_STATE=`echo "${SEFF_OUTPUT}" | grep "State:" | awk '{ print $2 }'`

# El job ha sigut cancelÂ·lat 
if [ "${JOB_STATE}" == "CANCELLED" ]; then
#	if [[ "${DEBUG}" == "true" ]]; then
                echo -e "\nJobID: ${JOBID} -> The job state is CANCELLED (${SLURM_JOB_EXIT_CODE}:${SLURM_JOB_EXIT_CODE2})" >> ${LOGFILE}
#	fi
        exit 0
fi

if [ "${JOB_STATE}" == "RUNNING" ]; then

	# Quan comencem amb precisiÃ³de milisegons
	START=$(date +%s.%N)
	
	# Mestres el job no estigui com COMPLETED donem voles al bucle, pero com a mÃ xim ho 
	# fem durant MAX_WAIT_TIME temps.
	until [ "${JOB_STATE}" == "COMPLETED" ]; do
        	JOB_STATE=`seff ${JOBID} | grep "State:" | awk '{ print $2 }'`
        	END=$(date +%s.%N)
        	if (( $(echo "(${END} - ${START}) > ${MAX_WAIT_TIME}" | bc -l) )); then
                	echo -e "\nJobID: ${JOBID} -> Max wating time for the job to be COMPLETED reached:  $(echo "${END} - ${START}" | bc -l) seconds" >> ${LOGFILE}
                	exit 0
        	fi
	done
	
	if [[ "${DEBUG}" == "true" ]]; then
                echo -e "\nJobID: ${JOBID} -> The job has spent $(echo "${END} - ${START}" | bc -l) seconds to reach the COMPLETED state." >> ${LOGFILE}
	fi
fi

# Ara anem a comprovar si està  per sobre del mínim % d'us definit com correcte:

# - Aquest bucle poder no cal. Es per saber en quina posició del la raw info tenin el waltime i la memoria demanda
# (es per evitar que si hi ha un canvi a la eina seff o al sacct, que sapiguem trobar si ha canviat la posició d'aquests valors).
# Es podria posar el index de on son per hardcode i llestos.

HEADER=`echo "${SEFF_OUTPUT}" | sed -n 1p`
VALUE=`echo "${SEFF_OUTPUT}" | sed -n 2p`
cnt=1
for i in ${HEADER}; do
        if [ $i == "Walltime" ]; then
	   INDEX_WTIME=$cnt
	fi
	if [ $i == "Reqmem" ]; then
           INDEX_MEM=$cnt
        fi
        ((++cnt))
done

# Atenció: si el job no es un array job, he de restar 1 als INDEX_MEM i INDEX_WTIME per que el camp de ArrayJobID no tindrà cap valor.
if [ ! ${SLURM_ARRAY_JOB_ID} ]; then 
	((--INDEX_MEM))
	((--INDEX_WTIME))
fi

# Primer comprovem si el walltime arriba a minim requerit
RAW_WALLTIME=`echo "${SEFF_OUTPUT}" | sed -n 2p | awk -v indice="${INDEX_WTIME}" 'BEGIN{OFS=IFS="\t"} { print $indice }'`

if [ "${RAW_WALLTIME}" -lt "$(( MIN_WALLTIME*60 ))" ]; then
	# No arriba al walltime, sortim.
	if [[ "${DEBUG}" == "true" ]]; then 
		echo -e "\nJobID: ${JOBID} -> Job Walltime ($(( RAW_WALLTIME/60 )) minutes) less than Minim Job Walltime (${MIN_WALLTIME} minutes)" >> ${LOGFILE}
	fi
	exit 0
fi

# Segon, fem el mateix amb la quantitat de memória demanada 
RAW_REQ_MEM=`echo "${SEFF_OUTPUT}" | sed -n 2p | awk -v indice="${INDEX_MEM}" 'BEGIN{OFS=IFS="\t"}{ print $indice }'`

if [ "${RAW_REQ_MEM}" -lt "$(( MIN_MEM*1024 ))" ]; then
	# No arriba a la memória mínima que s'ha de demanar, sortim.
	if [[ "${DEBUG}" == "true" ]]; then 
		echo -e "\nJobID: ${JOBID} -> Requested memory ($(( RAW_REQ_MEM/1024 ))Mb) less than Minim Memory (${MIN_MEM}Mb)" >> ${LOGFILE}
	fi
	exit 0
fi

# Tot correcte, ja podem mirar com ha anat el consum de memoria.
PERCENT_USED=`echo "${SEFF_OUTPUT}" | grep "Memory Efficiency" | awk '{ print $3 }'`

# He de treure el char '%' que està  al final:
VALUE_USED=${PERCENT_USED::-1}

# Ara comprovem si l'usuari ha fet servir prou memoria, si no es així­ li hem d'enviar un mail:
if (( $(echo "${VALUE_USED} < ${MIN_MEM_USED}" |bc -l) )); then

	# Hem d'avisar a l'usuari de que ha fet servir poca memória !!, preparem el mail:

	# Prapació del cos del mail (tmb fem servir aquesta info en el cas de que sigui un job array)
	MEMREQ=`echo "${SEFF_OUTPUT}" | grep "Memory Efficiency" | awk '{ print $5 $6 }'`
	MAXRSS=`echo "${SEFF_OUTPUT}" | grep "Memory Utilized" | awk '{ print $3 " " $4 }'`

	# Si surten les unitats del MAXRSS com a EB, vol dir que son KB, es raro nomÃs consumir KB  pero pasa,
	# ho diu el seff ...
	MAXRSS=`echo "${MAXRSS}" | sed -e "s/EB/KB/g"`

	echo -e "\nYour job with id ${JOBID} has asked for ${MEMREQ} of memory" > ${EMAILBODY}.${JOBID}
        echo -e "but it only has used ${MAXRSS} (which is the ${VALUE_USED}% of the requested memory). \n\n" >> ${EMAILBODY}.${JOBID}
        echo -e "Take into account that other jobs could have been waiting because they needed memory"  >> ${EMAILBODY}.${JOBID}
        echo -e "that your job has allocated but not used. \n\n"  >> ${EMAILBODY}.${JOBID}
        echo -e "Please, try to be more accurated with the amount of memory that you are going to ask for in your future jobs.\n\n"  >> ${EMAILBODY}.${JOBID}
        echo -e "Thank you. \n\n"  >> ${EMAILBODY}.${JOBID}

	if [[ "${DEBUG}" == "true" ]]; then
		# Si debug, afegin info sobre qui ha enviat el job per informat al IT team.
		echo -e "Username: ${SLURM_JOB_USER}\nLab Name: ${SLURM_JOB_ACCOUNT}" >> ${EMAILBODY}.${JOBID}
	fi

	if [[ "${IS_ARRAY}" == "false" ]]; then

		# Preparacio del recipient
        	if [[ "${DEBUG}" == "true" ]]; then
                	# Només avisem als técnics.
                	RECIPIENT=${IT_RECIPIENT}
        	else
			# Li pregunto al LDAP per el email de l'usuari.
                	RECIPIENT=`ldapsearch -h ${LDAP_SERVER} -b ${LDAP_BASEDN} -x "uid=${SLURM_JOB_USER}" | grep mail | awk '{ print $2 }'`
        	fi

        	# Preparacio del subject
        	SUBJECT="[MARVIN] Your Slurm job with id ${JOBID} has not used the asked amount of memory !!"

		# Enviem el mail
		if [ "${RECIPIENT}" == "" ]; then
			echo -e "WARNING !! User ${SLURM_JOB_USER} without email address in the LDAP service" >> ${EMAILBODY}.${JOBID} 
			${MAIL} -s "${SUBJECT}" ${IT_RECIPIENT} < ${EMAILBODY}.${JOBID}
		else
			${MAIL} -s "${SUBJECT}" ${RECIPIENT} < ${EMAILBODY}.${JOBID}
		fi
		rm -f ${EMAILBODY}.${JOBID}

        	# Guardem un log de a qui hem avisat
		SEFF2LOG=`echo "${SEFF_OUTPUT}" | sed '1,2d'`  # TreÃ¯em les dos primeres linies que es info de debug
		echo -e "\nJobID: ${JOBID} -> This job hasn't used the minimal amount of memory. We have sent an email to the user (${RECIPIENT}):\n${SEFF2LOG}\nNodelist: ${SLURM_JOB_NODELIST}" >> ${LOGFILE}

	else
		# Es un array job, hem de ficar la info d'aquest job amb la resta del jobarray. 
		if [ ! -f ${PATH_ARRAYJOBS}/${SLURM_ARRAY_JOB_ID} ]; then
			# Es crea el fitxer on guardarem la info dels jobs del arrayjobs que no han fer servir correctament els recursos demanats
			# i afegim info del job
                        echo -e "USERNAME: ${SLURM_JOB_USER}\nSome of the jobs which are part of the job array with id ${SLURM_ARRAY_JOB_ID} hasn't used correctly the\namount of memory reserved for the execution of the job:\n " >> ${PATH_ARRAYJOBS}/${SLURM_ARRAY_JOB_ID}

		fi
		
		MSG_TO_JARRAYFILE=`head -n3 ${EMAILBODY}.${JOBID}`
		echo -e "${MSG_TO_JARRAYFILE}" >> ${PATH_ARRAYJOBS}/${SLURM_ARRAY_JOB_ID}
		rm -f ${EMAILBODY}.${JOBID}
	
	fi

else
	# Ha fet servir el mínim de memoria requerida de la demanada
	if [[ "${DEBUG}" == "true" ]]; then
		 echo -e "\nJobID: ${JOBID} -> CONGRATULATIONS !! This job has used the ${VALUE_USED}% of the requested memory (the minimal is ${MIN_MEM_USED}%)" >> ${LOGFILE}

	fi
fi

# Abans d'acabar, comprovem si hi ha algun array job amb info pendent d'enviar

# Fiquem un semÃ for per evitar mes de un acces concurrent a aquesta part del
# escript per evitar problemes.

# -> SemÃ for vermell ...

if [ -f "${LOCK_FILE}" ]; then
    # Hi ha alguna execuciÃ del script del epilog que esta fent ja aquesta comprovacio, sortim.
    exit
else
    if [[ "${DEBUG}" == "true" ]]; then
        echo -e "\nJobID: ${JOBID} -> This job couldn't check the array jobs pending to send the email because the ${LOCK_FILE} is lock, red light." >> ${LOGFILE}
    fi
    touch ${LOCK_FILE}
fi

# Llistem els fitxers que están al directori ${ARRAYJOBS_INFO}
JARRAY_MONITORED=`ls ${PATH_ARRAYJOBS}`

for i in ${JARRAY_MONITORED}; do

	NUM_JOBS=`squeue -j ${i} -h | wc -l`
	if [ ${NUM_JOBS} -eq 0 ]; then
		
		USERNAME_JARRAY=`head -n1 ${PATH_ARRAYJOBS}/${i}`

		# Preparacio del subject
		SUBJECT="[MARVIN] Your Slurm array job with id ${i} has not used the asked amount of memory !!"

		# Preparacio del recipient
		if [[ "${DEBUG}" == "true" ]]; then
                	# Només avisem als técnics.
                	RECIPIENT=${IT_RECIPIENT}
        	else
			# Li pregunto al LDAP per el email de l'usuari.
                        RECIPIENT=`ldapsearch -h ${LDAP_SERVER} -b ${LDAP_BASEDN} -x "uid=${SLURM_JOB_USER}" | grep mail | awk '{ print $2 }'`
        	fi

		# Afegim el peu del body del mail
		echo -e "\nTake into account that other jobs could have been waiting because they needed memory"  >> ${PATH_ARRAYJOBS}/${i}
        	echo -e "that your job has allocated but not used. \n\n"  >> ${PATH_ARRAYJOBS}/${i}
        	echo -e "Please, try to be more accurated with the amount of memory that you are going to ask for in your future jobs.\n\n"  >> ${PATH_ARRAYJOBS}/${i}
        	echo -e "Thank you. \n\n"  >> ${PATH_ARRAYJOBS}/${i}
		
		# Abans d'enviar el mail hem de treure la primera linia que es on haivem guardar temporalment el username del usuari
		sed -i '1d' ${PATH_ARRAYJOBS}/${i}

		# I ara ja podem enviar el mail
		if [ "${RECIPIENT}" == "" ]; then
			sed -i '1s/^/"WARNING !! User ${USERNAME_JARRAY} without email address in the LDAP service"/'${PATH_ARRAYJOBS}/${i}
			${MAIL} -s "${SUBJECT}" ${IT_RECIPIENT} < ${PATH_ARRAYJOBS}/${i}
                else
                        ${MAIL} -s "${SUBJECT}" ${RECIPIENT} < ${PATH_ARRAYJOBS}/${i}
                fi

		rm -f ${PATH_ARRAYJOBS}/${i}

		if [[ "${DEBUG}" == "true" ]]; then
                      echo -e "\nJobID: ${i} -> This job was a job array and it has finished. We have sent an email to the user with the info of the jobs that hasn't used the asked amount of memory !! " >> ${LOGFILE}
             	fi

	fi
done

# ... semÃ for en verd.
rm -f ${LOCK_FILE}

exit 0


