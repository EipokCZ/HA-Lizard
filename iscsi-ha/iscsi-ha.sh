#!/bin/bash
##################################
# iSCSI-HA version 2.2.7
##################################
#################################################################################
#                                                                               #
# iscsi-ha - High Availability framework for iSCSI cluster used in conjunction  #
# with XAPI based Xen Virtualization Environment (Xen Cloud Platform/XenServer) #
# Copyright 2015 Salvatore Costantino                                           #
# ha@pulsesupply.com                                                            #
#                                                                               #
#                                                                               #
#    iscsi-ha is free software: you can redistribute it and/or modify           #
#    it under the terms of the GNU General Public License as published by       #
#    the Free Software Foundation, either version 3 of the License, or          #
#    (at your option) any later version.                                        #
#                                                                               #
#    iscsi-ha is distributed in the hope that it will be useful,                #
#    but WITHOUT ANY WARRANTY; without even the implied warranty of             #
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              #
#    GNU General Public License for more details.                               #
#                                                                               #
#    You should have received a copy of the GNU General Public License          #
#    along with iscsi-ha.  If not, see <http://www.gnu.org/licenses/>.          #
#                                                                               #
#################################################################################
source /etc/iscsi-ha/iscsi-ha.load
source /etc/iscsi-ha/iscsi-ha.conf
source /etc/iscsi-ha/iscsi-ha.func

ISCSI_TARGET_SERVICE=$(basename $ISCSI_TARGET_SERVICE)
log "Normalized ISCSI_TARGET_SERVICE [ $ISCSI_TARGET_SERVICE ]"

XS_RELEASE=$(cat /etc/redhat-release | tr -cd [:digit:])
XS_MAJOR_RELEASE=${XS_RELEASE:0:1}
log "XenServer Major Release = [ $XS_MAJOR_RELEASE ]"

if [ $1 ]
then
	SET_ARG1=$1
	log "Setting the action to [ $SET_ARG1 ]"

elif [ -e $IHA_STATE_PATH/manual ]
then
	log "system is currently in manual mode - checking manual role"
	SET_ARG1=$(cat $IHA_STATE_PATH/manual)
	log "manual role is set to [ $SET_ARG1 ]"
fi


if [ ! -e $STATUS ]
then
	touch $STATUS
fi

if [ -d $MAIL_SPOOL ]
then
	log "Mail Spool Directory Found $MAIL_SPOOL"
else
	mkdir $MAIL_SPOOL
	if [ $? = 0 ]
	then
		log "Successfully created mail spool directory $MAIL_SPOOL"
	else
		log "Failed to create mail spool - not suppressing duplicate notices"
	fi
fi

if [ ! -f $MAIL_SPOOL/count ]
then
	touch $MAIL_SPOOL/count
	echo 0 > $MAIL_SPOOL/count
fi

CURRENT_COUNT=`cat $MAIL_SPOOL/count`

if [ $CURRENT_COUNT -gt 10000 ]
then
	log "Resetting iteration counter"
	echo 1 > $MAIL_SPOOL/count
	CURRENT_COUNT=0
fi

NEW_COUNT=$(($CURRENT_COUNT + 1))
log "This iteration is count $NEW_COUNT"
echo $NEW_COUNT > $MAIL_SPOOL/count

if [ $NEW_COUNT -eq 1 ]
then
	MP_FILTER_FILE="/etc/multipath/conf.d/iscsi-ha.conf"
	log "Checking if multipathd filters are in place"
	if [ ! -e $MP_FILTER_FILE ]
	then
		log "Creating missing multipathd filters"
		echo -e 'blacklist {\n  devnode "drbd[0-9]*"\n}' > ${MP_FILTER_FILE}
		service_execute multipathd reload
	fi
fi

if [ -e /etc/xensource/pool.conf ]
then
	log "Checking if this host is a Pool Master or Slave"
	STATE=`/bin/cat /etc/xensource/pool.conf`
	log "This host's pool status = $STATE"
else
	log "/etc/xensource/pool.conf missing. Cannot determine master/slave status."
	email "/etc/xensource/pool.conf missing. Cannot determine master/slave status." "1"
	exit 1
fi


if [ $STATE = "master" -o  "$SET_ARG1" = "become_primary" ] && [ "$SET_ARG1" != "become_secondary" ]
then
	if [ "$NEW_COUNT" -gt 5 ]
	then	
		( auto_plug_pbd && $TIMEOUT 10 /etc/iscsi-ha/scripts/replug_pbd --silent ) &
	fi

	> $STATUS
	service_execute $PROG_NAME status > /dev/null
	RETVAL=$?
	if [ $RETVAL -eq 0 ]
	then
		SERVICE_STATUS=Running
		SERVICE_STATUS="${SERVICE_STATUS} $(cat /var/run/$PROG_NAME.pid)"
	else
		SERVICE_STATUS=Stopped
	fi
	echo "iSCSI-HA Status: $SERVICE_STATUS" >> $STATUS
	echo  "Last Updated: `date`" >> $STATUS
	echo "HOST ROLE:		MASTER" >> $STATUS

	while : 
	do
		if [ -a /proc/drbd ]
		then
			DRBD_STATUS=`cat /proc/drbd`
			log "DRBD Running on this host: "$DRBD_STATUS""
			validate_drbd_resources_loaded
			RETVAL=$?
			if [ $RETVAL -eq 0 ]
			then
				break
			else
				service_execute drbd restart
			fi
		else
			log "DRBD not running - attempting start"
			email "DRBD not running - attempting start" "1"
			service_execute drbd start
			if [ $? -eq 0 ]
			then
				if [ -a /proc/drbd ]
				then
					DRBD_STATUS=$(cat /proc/drbd)
					log "Successfully started DRBD: [$DRBD_STATUS]"
					email "DRBD recovered: Successfully started DRBD: [$DRBD_STATUS]" "4"
					validate_drbd_resources_loaded
					RETVAL=$?
					if [ $RETVAL -eq 0 ]
					then
						break
					fi
				else
					log "DRBD not running - attempted start failed"
					email "DRBD not running - attempted start failed" "!"
				fi
			else
				log "DRBD not running - attempted start failed"
				email "DRBD not running - attempted start failed" "1"
			fi
		fi

		sleep 10 # delay a bit before reattempting start
	done

	RESTORE_IFS=$IFS
	IFS=:

	for resource in ${DRBD_RESOURCES[@]}
	do
		check_drbd_resource_state $resource Primary
		if [ $? -ne 0 ]
		then
			drbdadm primary $resource
			if [ $? -eq 0 ]
			then
				log "DRBD Resource: [$resource] successfully transitioned to Primary"
				email "DRBD Resource: [$resource] successfully transitioned to Primary" "4"
			else
				log "DRBD Resource: [$resource] failed transition to Primary"
				email "DRBD Resource: [$resource] failed transition to Primary" "1"
				log "Aborting promote to primary"
				exit 1
			fi
		else
			echo "DRBD ROLE:		$resource=Primary" >> $STATUS
		fi
	done
	IFS=$RESTORE_IFS

	RESTORE_IFS=$IFS
	IFS=":"
	DRBD_LINK_OK=true
	for resource in ${DRBD_RESOURCES[@]}
	do
		CONNECTION=`drbdadm cstate $resource`
		case $CONNECTION in
		Connected)
			log "DRBD Resource: $resource in $CONNECTION state"
			echo "DRBD CONNECTION:	$resource in $CONNECTION state" >> $STATUS
			;;
		SyncSource|SyncTarget)
			log "DRBD resource: $resource is currently syncing [$CONNECTION]"
			echo "DRBD CONNECTION:  $resource in $CONNECTION state" >> $STATUS
			;;
		*)
			DRBD_LINK_OK=false
			log "DRBD Resource: $resource in [$CONNECTION] state - expected Connected state"
			echo "DRBD CONNECTION: 	$resource in $CONNECTION state" >> $STATUS
			email "DRBD Resource: $resource in [$CONNECTION] state - expected Connected state" "1"
			;;
		esac
		
	unset $CONNECTION
	done
	IFS=$RESTORE_IFS	
	
	RESTORE_IFS=$IFS
	IFS=":"
	DRBD_LINK_OK=true
	for resource in ${DRBD_RESOURCES[@]}
	do
		D_STATE=`drbdadm dstate $resource`
		if [ "$D_STATE" != "UpToDate/UpToDate" ]
		then
			DRBD_LINK_OK=false
			log "DRBD Resource: $resource in [$D_STATE] disk state - expected [UpToDate/UpToDate]"
			echo "DRBD Disk State: 	$resource in $D_STATE state" >> $STATUS
			email "DRBD Resource: $resource in [$D_STATE] disk state - expected [UpToDate/UpToDate]" "1"
		else
			log "DRBD Resource: $resource in [$D_STATE] disk state"
			echo "DRBD Disk State:	$resource in $D_STATE disk state" >> $STATUS
		fi
		unset $D_STATE
	done
	IFS=$RESTORE_IFS	

	SERVICE_EXECUTE_REQ=$(service_execute $ISCSI_TARGET_SERVICE status)
	RETVAL=$?
	if [ $RETVAL -eq 0 ]
	then
		ISCSI_TARGET_STATUS=Running
	else
		ISCSI_TARGET_STATUS=Stopped
	fi

	SERVICE_EXECUTE_RESULT=$(echo "$SERVICE_EXECUTE_REQ" |  grep 'Active' | $AWK -F 'Active: ' {'print $2'})
	echo "ISCSI TARGET:		$ISCSI_TARGET_STATUS [expected running]" >> $STATUS 

	if [ $RETVAL -eq 0 ]
	then
		log "iSCSI target: $ISCSI_TARGET_SERVICE status = OK. [ $SERVICE_EXECUTE_RESULT ]"
	else
		log "iSCSI target: $ISCSI_TARGET_SERVICE status not OK . [$SERVICE_EXECUTE_RESULT]"
		log "Attempting to start iSCSI target $ISCSI_TARGET_SERVICE"
		service_execute tgtd start && SERVICE_EXECUTE_RESULT=$(service_execute $ISCSI_TARGET_SERVICE status)
		RETVAL=$?
		if [ $RETVAL -eq 0 ]
		then
			log "iSCSI target: $ISCSI_TARGET_SERVICE status = OK. [ $SERVICE_EXECUTE_RESULT ]"
		else
			if [ $XS_MAJOR_RELEASE -eq 6 ]
			then
				log "Legacy mode start failed with result [ $RETVAL ] - removing lock"
				TARGET_PIDS=$(pidof $ISCSI_TARGET_SERVICE)
				for pid in ${TARGET_PIDS[@]}
				do
					log "Attempting to kill PID $pid"
					kill -9 $pid
					if [ $? -eq 0 ]
					then
						log "Successfully killed PID $pid"
					else
						log "Error killing PID $pid."
					fi
				done
				rm -f /var/lock/subsys/$ISCSI_TARGET_SERVICE
				log "Reattempting start"
				service_execute tgtd start && service_execute $ISCSI_TARGET_SERVICE status
				RETVAL=$?
			fi
 
			if [ $RETVAL -ne 0 ]
			then
				log "Failed to initialize iSCSI target service. [$SERVICE_EXECUTE_RESULT]"
				email "Failed to initialize iSCSI target service. [$SERVICE_EXECUTE_RESULT]" "1"
			fi
		fi
	fi


	local_ip_list
	RETVAL=$?
	if [ $RETVAL -eq 0 ]
	then
		for IPADDR in  ${LOCAL_IP_LIST[@]}
		do
			log "CHECKING IP $IPADDR"
			if [ $IPADDR = "$DRBD_VIRTUAL_IP" ]
			then
				VIP_IS_LOCAL=1
				log "Virtual IP: $DRBD_VIRTUAL_IP discovered on host $HOST"
				echo "VIRTUAL IP:		$DRBD_VIRTUAL_IP is local" >> $STATUS
				break
			fi
		done
		send_replication_network_arp 
	
		if [ "$VIP_IS_LOCAL" != "1" ]
		then
			check_ip_health $DRBD_VIRTUAL_IP 1
			if [ $? -eq 1 ]
			then
				log "Virtual IP $DRBD_VIRTUAL_IP expected local, not found. Initializing.."
				mask_numbits $DRBD_VIRTUAL_MASK
				ip addr add "$DRBD_VIRTUAL_IP/$BITS" dev $DRBD_INTERFACE
				if [ $? -eq 0 ]
				then
					log "DRBD Virtual IP: $DRBD_VIRTUAL_IP successfully added to local interface [$DRBD_INTERFACE]"
					email "Storage Virtual IP: $DRBD_VIRTUAL_IP successfully added to local interface [$DRBD_INTERFACE]" "4"
					echo "VIRTUAL IP:               $DRBD_VIRTUAL_IP is local" >> $STATUS
					log "Updating ARP for $DRBD_VIRTUAL_IP"
					$ARPING -I $DRBD_INTERFACE -U $DRBD_VIRTUAL_IP -c 2 -w 2
				else
					log "Failed to add $DRBD_VIRTUAL_IP on local interface $DRBD_INTERFACE"
					echo "VIRTUAL IP:		Failed to add $DRBD_VIRTUAL_IP on local interface $DRBD_INTERFACE" >> $STATUS
					email "Host: $HOST Failed to add [$DRBD_VIRTUAL_IP] on local interface [$DRBD_INTERFACE]" "1"
				fi
			else
				log "Host: [$HOST]: DRBD Virtual IP: [$DRBD_VIRTUAL_IP] found on other host - should be here"
				echo "VIRTUAL IP:		$DRBD_VIRTUAL_IP found on other host - should be here" >> $STATUS
				email "Host: [$HOST]: DRBD Virtual IP: [$DRBD_VIRTUAL_IP] found on other host - should be here" "1"
			fi	
		fi
	fi

	echo "$BREAK" >> $STATUS        

	if (($NEW_COUNT % 15 == 0))
	then
		log "replication_link_check on this loop"
		if [ "$DRBD_LINK_OK" = "false" ] && [ "$STATE" = "master" ]
		then
			log "Calling replication_link_check DRBD_LINK_OK=[$DRBD_LINK_OK] STATE=[$STATE] MANUAL_MODE=[${SET_ARG1:-off}]"
			replication_link_check $DRBD_INTERFACE
		else
			log "conditions not met for replication_link_check"
		fi
	else
		log "Skipping replication_link_check DRBD_LINK_OK=[$DRBD_LINK_OK] STATE=[$STATE] MANUAL_MODE=[${SET_ARG1:-off}]"
	fi

	exit 0
fi


if [[ $STATE == slave* ]] || [ "$SET_ARG1" = "become_secondary" ]
then
	> $STATUS
	service_execute $PROG_NAME status > /dev/null
	RETVAL=$?
	if [ $RETVAL -eq 0 ]
	then
		SERVICE_STATUS=Running
		SERVICE_STATUS="${SERVICE_STATUS} $(cat /var/run/$PROG_NAME.pid)"
	else
		SERVICE_STATUS=Stopped
	fi
	echo "iSCSI-HA Status: $SERVICE_STATUS" >> $STATUS
	echo "Last Updated: `date`" >> $STATUS
	echo "HOST ROLE:              SLAVE" >> $STATUS

	$TIMEOUT 10 /etc/iscsi-ha/scripts/replug_pbd --silent &

	local_ip_list
	if [ $? -eq 0 ]
	then
		for IPADDR in  ${LOCAL_IP_LIST[@]}
		do
			if [ $IPADDR = "$DRBD_VIRTUAL_IP" ]
			then
				VIP_IS_LOCAL=1
				log "Virtual IP: $DRBD_VIRTUAL_IP discovered on host $HOST"
				break
			fi
		done

		if [ "$VIP_IS_LOCAL" = "1" ]
		then
			log "Virtual IP $DRBD_VIRTUAL_IP found local, expected remote. Removing $DRBD_VIRTUAL_IP from this host."
			mask_numbits $DRBD_VIRTUAL_MASK
			$IP addr del "$DRBD_VIRTUAL_IP/$BITS" dev $DRBD_INTERFACE
			if [ $? -eq 0 ]
			then
				log "DRBD Virtual IP: [$DRBD_VIRTUAL_IP] successfully removed from interface [$DRBD_INTERFACE]"
			else
				log "Host: [$HOST]: Failed to remove $DRBD_VIRTUAL_IP on local interface [$DRBD_INTERFACE]"
				email "Host: [$HOST]: Failed to remove $DRBD_VIRTUAL_IP on local interface [$DRBD_INTERFACE]" "1"
			fi
		else
			echo "VIRTUAL IP:		$DRBD_VIRTUAL_IP is not local" >> $STATUS
		fi
	fi

	SERVICE_EXECUTE_REQ=$(service_execute $ISCSI_TARGET_SERVICE status)
	RETVAL=$?
	SERVICE_EXECUTE_RESULT=$(echo "$SERVICE_EXECUTE_REQ" | grep 'Active' | $AWK -F 'Active: ' {'print $2'})
	if [ $RETVAL -eq 0 ]
	then
		ISCSI_TARGET_STATUS=Running
	else
		ISCSI_TARGET_STATUS=Stopped
	fi

	echo "ISCSI TARGET:		$ISCSI_TARGET_STATUS [expected stopped]" >> $STATUS

	if [ $RETVAL -eq 0 ]
	then
		log "iSCSI target: $ISCSI_TARGET_SERVICE status = OK. [$SERVICE_EXECUTE_RESULT], expected stopped"
		log "Attempting to stop $ISCSI_TARGET_SERVICE"

		if [ "$XS_MAJOR_RELEASE" -eq 6 ]
		then
			log "Release [ $XS_MAJOR_RELEASE ] detected - using legacy mode"
			service_execute $ISCSI_TARGET_SERVICE forcedstop
			RETVAL=$?
		else
			if [ -e $TARGET_DROP_IN_FILE ]
			then
				service_execute $ISCSI_TARGET_SERVICE stop
				RETVAL=$?
	
			else
				make_target_drop_in
				service_execute $ISCSI_TARGET_SERVICE stop
				RETVAL=$?
			fi
		fi

		if [ $RETVAL -ne 0 ]
		then
			log "Failed to stop iSCSI target on $HOST. Attempting kill"
			TARGET_NAME=ISCSI_TARGET_SERVICE
			TARGET_PIDS=`pidof $TARGET_NAME`
			for pid in ${TARGET_PIDS[@]}
			do
				log "Attempting to kill PID $pid"
				kill -9 $pid
				if [ $? -eq 0 ]
				then
					log "Successfully killed PID $pid"
				else
					log "Error killing PID $pid."
				fi
			done
			log "Checking iSCSI Target Service"
			SERVICE_EXECUTE_REQ=$(service_execute $ISCSI_TARGET_SERVICE status)
			RETVAL=$?
			SERVICE_EXECUTE_RESULT=$(echo "$SERVICE_EXECUTE_REQ" | grep 'Active' | $AWK -F 'Active: ' {'print $2'})
			if [ $RETVAL -eq 3  ]
			then
				log "iSCSI target stopped [$SERVICE_EXECUTE_RESULT]"
			else
				log "Host: $HOST: Error stopping iSCSI target [$SERVICE_EXECUTE_RESULT]"
				email "Host: $HOST: Error stopping iSCSI target [$SERVICE_EXECUTE_RESULT]" "1"
			fi
		else
			log "Service $ISCSI_TARGET_SERVICE successfully stopped"
		fi				

	elif [ $RETVAL -eq 3 ]
	then
		log "iSCSI target: $ISCSI_TARGET_SERVICE status stopped. Expected Stopped . [$SERVICE_EXECUTE_RESULT]"

	elif [ $RETVAL -eq 2 ]
	then
		log "iSCSI target: $ISCSI_TARGET_SERVICE status locked. Expected Stopped . [$SERVICE_EXECUTE_RESULT]"
		service_execute $ISCSI_TARGET_SERVICE stop
		if [ $? = "0" ]
		then
			log "Successfully stopped $ISCSI_TARGET_SERVICE"
		fi

	elif [ $RETVAL -eq 1 ]
	then
		log "iSCSI target: $ISCSI_TARGET_SERVICE status dead but pid file exists. Expected Stopped . [$SERVICE_EXECUTE_RESULT]"
		service_execute $ISCSI_TARGET_SERVICE stop
		if [ $? = "0" ]
		then
			log "Successfully stopped $ISCSI_TARGET_SERVICE"
		fi

	else
		log "Host: [$HOST]: iSCSI Target in unexpected state [$SERVICE_EXECUTE_RESULT]"
		email "Host: [$HOST]: iSCSI Target in unexpected state [$SERVICE_EXECUTE_RESULT]" "1"
	fi

	while :
	do
		if [ -a /proc/drbd ]
		then
			DRBD_STATUS=`cat /proc/drbd`
			log "DRBD Running on this host: $DRBD_STATUS"
			validate_drbd_resources_loaded
			RETVAL=$?
			if [ $RETVAL -eq 0 ]
			then
				break
			else
				service_execute drbd restart
			fi
		else
			log "DRBD not running - attempting start"
			email "DRBD not running - attempting start" "1"
			service_execute drbd start
			if [ $? -eq 0 ]
			then
				if [ -a /proc/drbd ]
				then
					DRBD_STATUS=`cat /proc/drbd`
					log "Successfully started DRBD: [$DRBD_STATUS]"
					email "DRBD recovered: Successfully started DRBD: [$DRBD_STATUS]" "4"
					validate_drbd_resources_loaded
					RETVAL=$?
					if [ $RETVAL -eq 0 ]
					then
						break
					fi
				else
					log "DRBD not running - attempted start failed"
					email "DRBD not running - attempted start failed" "1"
				fi
			else
				log "DRBD not running - attempted start failed"
				email "DRBD not running - attempted start failed" "1"
			fi
		fi
		sleep 10
	done

	RESTORE_IFS=$IFS
	IFS=:

	for resource in ${DRBD_RESOURCES[@]}
	do
		check_drbd_resource_state $resource Secondary
		if [ $? -ne 0 ]
		then
			drbdadm secondary $resource
			if [ $? -eq 0 ]
			then
				log "DRBD Resource: [$resource] successfully transitioned to Secondary"
				email "DRBD Resource: [$resource] successfully transitioned to Secondary" "4"
			else
				log "DRBD Resource: $resource failed transition to Secondary"
				email "DRBD Resource: [$resource] failed transition to Secondary" "1"
			fi
		else
			echo "DRBD ROLE:		$resource=Secondary" >> $STATUS
		fi
	done
	IFS=$RESTORE_IFS

	RESTORE_IFS=$IFS
	IFS=":"
	DRBD_LINK_OK=true
	for resource in ${DRBD_RESOURCES[@]}
	do
		CONNECTION=$(drbdadm cstate $resource)
		case $CONNECTION in
			Connected)
				log "DRBD Resource: $resource in $CONNECTION state"
				echo "DRBD CONNECTION: 	$resource in $CONNECTION state" >> $STATUS
				;;
			SyncSource|SyncTarget)
				log "DRBD resource: $resource is currently syncing [$CONNECTION]"
				echo "DRBD CONNECTION:  $resource in $CONNECTION state" >> $STATUS
				;;
			*)
				DRBD_LINK_OK=false
				log "DRBD Resource: [$resource] in [$CONNECTION] state - expected Connected state"
				echo "DRBD CONNECTION: 	$resource in $CONNECTION state" >> $STATUS
				email "DRBD Resource:       [$resource] in [$CONNECTION] state - expected Connected state" "1"
				;;
		esac
	done
	echo "$BREAK" >> $STATUS
fi

IFS=$RESTORE_IFS
if (($NEW_COUNT % 15 == 0))
then
	log "replication_link_check on this loop"
	if [ "$DRBD_LINK_OK" = "false" ] && [ "$STATE" = "master" ]
	then
		log "Calling replication_link_check DRBD_LINK_OK=[$DRBD_LINK_OK] STATE=[$STATE] MANUAL_MODE=[${SET_ARG1:-off}]"
		replication_link_check $DRBD_INTERFACE
	else
		log "conditions not met for replication_link_check"
	fi
else
	log "Skipping replication_link_check DRBD_LINK_OK=[$DRBD_LINK_OK] STATE=[$STATE] MANUAL_MODE=[${SET_ARG1:-off}]"
fi

