#!/bin/bash
export PATH=$PATH:/usr/bin:/usr/local/bin:/bin

set -x


source ./notifications.sh

script_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

. $script_path/paths_from_volumes.sh

function cleanup {
  # If a post-backup command is defined (eg: for cleanup)
  if [ -n "$AFTER_BACKUP_CMD" ]; then
    eval "$AFTER_BACKUP_CMD"
  fi
}

start_time=`date +%Y-%m-%d\\ %H:%M:%S\\ %Z`
SECONDS=0
echo "[$start_time] Initiating backup $BACKUP_NAME..."

# Get timestamp
: ${BACKUP_SUFFIX:=.$(date +"%Y-%m-%d-%H-%M-%S")}
tarball=$BACKUP_NAME$BACKUP_SUFFIX.tar.gz

# If a pre-backup command is defined, run it before creating the tarball
if [ -n "$BEFORE_BACKUP_CMD" ]; then
	eval "$BEFORE_BACKUP_CMD"
  rc=$?
  if [ $rc -ne 0 ]; then
    # early exit
    notifyFailure "Error performing backup preparation task."
    exit $rc
  fi
fi

# Create a gzip compressed tarball with the volume(s)
tar_try=0
until [ $tar_try -ge $BACKUP_TAR_TRIES ]
do
  if [ "$CONTENT_ONLY" == "true" ]; then
   cd $PATHS_TO_BACKUP
   time tar czf $script_path/$tarball $BACKUP_TAR_OPTION .
   cd $WORKDIR
  else
   time tar czf $script_path/$tarball $BACKUP_TAR_OPTION $PATHS_TO_BACKUP
  fi

  rc=$?
  if [ $rc -eq 0 ]; then
    echo "Created archive $tarball"
    break
  else
    tar_try=$[$tar_try+1]
    rm $script_path/$tarball
    if [ ! $tar_try -ge $BACKUP_TAR_TRIES ]; then
      echo "Attempt to create archive failed, retrying..."
      sleep $BACKUP_TAR_RETRY_SLEEP
    fi
  fi
done

if [ $rc -ne 0 ]; then
  # early exit
  notifyFailure "Error creating backup archive."
  cleanup
  end_time=`date +%Y-%m-%d\\ %H:%M:%S\\ %Z`
  echo -e "[$end_time] Backup failed\n\n"
  exit $rc
fi

# encrypt archive
if [ -n "$GPG_KEYNAME" -a -n "$GPG_KEYRING" ]; then
  echo "Encrypting backup archive..."
  time gpg --batch --no-default-keyring --keyring "$GPG_KEYRING" --trust-model always --encrypt --recipient "$GPG_KEYNAME" $script_path/$tarball
  rc=$?
  if [ $rc -ne 0 ]; then
    # early exit
    notifyFailure "Error encrypting backup archive."
    rm $script_path/$tarball
    cleanup
    exit $rc;
  fi
  echo "Encryption completed successfully"
  # remove original tarball and point to encrypted file
  rm $script_path/$tarball
  tarball="$tarball.gpg"
else
  echo "Encryption not configured...skipping"
fi

backup_size=$(du -h "$script_path/$tarball" | tr '\t' '\n' | grep -v "$script_path/$tarball")

# Create bucket, if it doesn't already exist (only try if listing is successful - access may be denied)
BUCKET_LS=$(aws s3 --region $AWS_DEFAULT_REGION ls)
if [ $? -eq 0 ]; then
  BUCKET_EXIST=$(echo $BUCKET_LS | grep $S3_BUCKET_NAME | wc -l)
  if [ $BUCKET_EXIST -eq 0 ];
  then
    aws s3 --region $AWS_DEFAULT_REGION mb s3://$S3_BUCKET_NAME
  fi
fi

# Upload the backup to S3 with timestamp
echo "Uploading the archive to S3..."
time aws s3 --region $AWS_DEFAULT_REGION cp $script_path/$tarball "s3://${S3_BUCKET_NAME}/${S3_FOLDER}${tarball}"
rc=$?

# Clean up
rm $script_path/$tarball
cleanup

end_time=`date +%Y-%m-%d\\ %H:%M:%S\\ %Z`
backup_duration=`date -u -d @"$SECONDS" +'%-Mm %-Ss'`
if [ $rc -ne 0 ]; then
  notifyFailure "Error uploading backup to S3."
  echo -e "[$end_time] Backup failed\n\n"
  exit $rc
else
  notifySuccess
  echo -e "[$end_time] Archive successfully uploaded to S3\n\n"
fi
