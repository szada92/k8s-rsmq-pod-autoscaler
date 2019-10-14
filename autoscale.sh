#!/bin/bash

namespace=""
deployment=""

function getCurrentPods() {
  # Retry up to 5 times if kubectl fails
  for i in $(seq 5); do
    current=$(kubectl -n $namespace describe deploy $deployment | \
      grep desired | awk '{print $2}' | head -n1)

    if [[ $current != "" ]]; then
      echo $current
      return 0
    fi

    sleep 3
  done

  echo ""
}

function notifySlack() {
  if [ -z "$SLACK_HOOK" ]; then
    return 0
  fi

  curl -s --retry 3 --retry-delay 3 -X POST --data-urlencode 'payload={"text": "'"$1"'"}' $SLACK_HOOK > /dev/null
}

autoscalingNoWS=$(echo "$AUTOSCALING" | tr -d "[:space:]")
IFS=';' read -ra autoscalingArr <<< "$autoscalingNoWS"

declare -A downscaleWaitTicksArray
for autoscaler in "${autoscalingArr[@]}"; do
  downscaleWaitTicksArray[$autoscaler]=$DOWNSCALE_WAIT_TICKS
done

while true; do
  for autoscaler in "${autoscalingArr[@]}"; do
    IFS='|' read minPods maxPods mesgPerPod namespace deployment queueName <<< "$autoscaler"

    if [ -n "$REDIS_PASSWORD" ]; then
      queueMessagesJson=$(rsmq stats --host ${REDIS_HOST} --port ${REDIS_PORT} --clientopt password=${REDIS_PASSWORD} --qname ${queueName})
    else
      queueMessagesJson=$(rsmq stats --host ${REDIS_HOST} --port ${REDIS_PORT} --qname ${queueName})
    fi

    if [[ $? -eq 0 ]]; then
      totalQueueMessages=$(echo $queueMessagesJson | jq '.msgs')
      hiddenQueueMessages=$(echo $queueMessagesJson | jq '.hiddenmsgs')
      queueMessages=$((totalQueueMessages-hiddenQueueMessages))

      requiredPods=$(echo "$queueMessages/$mesgPerPod" | bc 2> /dev/null)

      if [[ $requiredPods != "" ]]; then
        currentPods=$(getCurrentPods)

        if [[ $currentPods != "" ]]; then
          if [[ $requiredPods -ne $currentPods ]]; then
            desiredPods=""
            # Flag used to prevent scaling down or up if currentPods are already min or max respectively.
            scale=0

            if [[ $requiredPods -le $minPods ]]; then
              desiredPods=$minPods

              # If currentPods are already at min, do not scale down
              if [[ $currentPods -eq $minPods ]]; then
                scale=1
              fi
            elif [[ $requiredPods -ge $maxPods ]]; then
              desiredPods=$maxPods

              # If currentPods are already at max, do not scale up
              if [[ $currentPods -eq $maxPods ]]; then
                scale=1
              fi
            else
              desiredPods=$requiredPods
            fi

            if [[ $scale -eq 0 ]]; then
              # To slow down the scale-down policy, scale down in steps (reduce 10% on every iteration)
              if [[ $desiredPods -lt $currentPods ]]; then

                if [[ ${downscaleWaitTicksArray[$autoscaler]} -gt 0 ]]; then
                  downscaleWaitTicksArray[$autoscaler]=$((downscaleWaitTicksArray[$autoscaler]-1))

                  echo "$(date) -- Waiting another ${downscaleWaitTicksArray[$autoscaler]} iteration for downscaling $namespace: $deployment to $desiredPods pods (unprocessed msgs: $queueMessages; total msgs: $totalQueueMessages)"
                  notifySlack "Waiting another ${downscaleWaitTicksArray[$autoscaler]} iteration for downscaling $namespace: $deployment to $desiredPods pods (unprocessed msgs: $queueMessages; total msgs: $totalQueueMessages)"

                  continue
                else
                  downscaleWaitTicksArray[$autoscaler]=$DOWNSCALE_WAIT_TICKS
                fi

                desiredPods=$(awk "BEGIN { print int( ($currentPods - $desiredPods) * 0.9 + $desiredPods ) }")
              else
                downscaleWaitTicksArray[$autoscaler]=$DOWNSCALE_WAIT_TICKS
              fi

              kubectl scale -n $namespace --replicas=$desiredPods deployment/$deployment 1> /dev/null

              if [[ $? -eq 0 ]]; then
                # Adjust logging and Slack notifications based on LOGS env and desiredPods number
                log=false
                avgPods=$(awk "BEGIN { print int( ($minPods + $maxPods) / 2 ) }")

                if [[ $LOGS == "HIGH" ]]; then
                  log=true
                elif [[ $LOGS == "MEDIUM" && ($desiredPods -eq $minPods || $desiredPods -eq $avgPods || $desiredPods -eq $maxPods) ]]; then
                  log=true
                elif [[ $LOGS == "LOW" && ($desiredPods -eq $minPods || $desiredPods -eq $maxPods) ]]; then
                  log=true
                fi

                if $log ; then
                  echo "$(date) -- Scaled $namespace: $deployment to $desiredPods pods ($queueMessages msg in RedisMQ)"
                  notifySlack "Scaled $namespace: $deployment to $desiredPods pods ($queueMessages msg in RedisMQ)"
                fi
              else
                echo "$(date) -- Failed to scale $namespace: $deployment pods."
                notifySlack "Failed to scale $namespace: $deployment pods."
              fi
            fi
          fi
        else
          echo "$(date) -- Failed to get current pods number for $namespace: $deployment."
          notifySlack "Failed to get current pods number for $namespace: $deployment."
        fi
      else
        echo "$(date) -- Failed to calculate required pods for $namespace: $deployment."
        notifySlack "Failed to calculate required pods for $namespace: $deployment."
      fi
    else
      echo "$(date) -- Failed to get queue messages from $REDIS_HOST for $namespace: $deployment."
      notifySlack "Failed to get queue messages from $REDIS_HOST for $namespace: $deployment."
    fi
  done

  sleep $INTERVAL
done
