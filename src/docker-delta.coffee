path = require 'path'
{ spawn } = require 'child_process'

Promise = require 'bluebird'
stream = require 'readable-stream'

rsync = require './rsync'
btrfs = require './btrfs'
utils = require './utils'
Docker = require './docker-toolbelt'

docker = new Docker()

# Takes two strings `srcImage` and `destImage` which represent docker images
# that are already present in the docker daemon and returns a Readable stream
# of the binary diff between the two images.
#
# The stream format is the following where || means concatenation:
#
# result := jsonMetadata || 0x00 || rsyncData
exports.createDelta = (srcImage, destImage) ->
	# We need a passthrough stream so that we can return it immediately while the
	# promises are in progress
	deltaStream = new stream.PassThrough()

	# We first get the two root directories and then apply rsync on them
	rsyncStream = Promise.resolve [ srcImage, destImage ]
		.bind(docker)
		.map(docker.imageRootDir)
		.map (rootDir) ->
			path.join(rootDir, '/')
		.spread(rsync.createRsyncStream)
		.catch (e) ->
			deltaStream.emit('error', e)

	# We also retrieve the container config for the image
	config = docker.getImage(destImage).inspectAsync().get('Config')

	Promise.all [ config, rsyncStream ]
	.spread (config, rsyncStream) ->
		metadata =
			version: 2
			dockerConfig: config

		# Write the header of the delta format which is the serialised metadata
		deltaStream.write(JSON.stringify(metadata))
		# Write the NUL byte separator for the rsync binary stream
		deltaStream.write(Buffer.from([ 0x00 ]))
		# Write the rsync binary stream
		rsyncStream.pipe(deltaStream)
	.catch (e) ->
		deltaStream.emit('error', e)

	return deltaStream

# Parses the input stream `input` and returns a promise that will resolve to
# the parsed JSON metadata of the delta stream. The input stream is consumed
# exactly up to and including the separator so that it can be piped directly
# to rsync after the promise resolves.
parseDeltaStream = (input) ->
	new Promise (resolve, reject) ->
		buf = new Buffer(0)

		parser = ->
			# Read all available data
			chunks = [ buf ]
			while input._readableState.length > 0
				chunks.push(input.read())

			# FIXME: Implement a sensible upper bound on the size of metadata
			# and reject with an error if we get above that
			buf = Buffer.concat(chunks)

			sep = buf.indexOf(0x00)

			if sep isnt -1
				# We no longer have to parse the input
				input.removeListener('readable', parser)

				# The data after the separator are rsync binary data so we put
				# them back for the next consumer to process
				input.unshift(buf[sep + 1...])

				# Parse JSON up until the separator
				metadata = JSON.parse(buf[...sep])

				# Sanity check
				if metadata.version is 2
					resolve(metadata)
				else
					reject(new Error('Uknown version: ' + metadata.version))

		input.on('readable', parser)

exports.applyDelta = (srcImage, dstImage) ->
	deltaStream = new stream.PassThrough()

	dstId = parseDeltaStream(deltaStream).get('dockerConfig').bind(docker).then(docker.createEmptyImage)

	Promise.all [
		docker.infoAsync().get('Driver')
		docker.imageRootDir(srcImage)
		dstId
		dstId.then(docker.imageRootDir)
	]
	.spread (dockerDriver, srcRoot, dstId, dstRoot) ->
		# trailing slashes are significant for rsync
		srcRoot = path.join(srcRoot, '/')
		dstRoot = path.join(dstRoot, '/')

		rsyncArgs = [
			'--timeout', '300'
			'--archive'
			'--delete'
			'--read-batch', '-'
			dstRoot
		]

		Promise.attempt ->
			switch dockerDriver
				when 'btrfs'
					btrfs.deleteSubvolAsync(dstRoot)
					.then ->
						btrfs.snapshotSubvolAsync(srcRoot, dstRoot)
				when 'overlay'
					rsyncArgs.push('--link-dest', srcRoot)
				else
					throw new Error("Unsupported driver #{dockerDriver}")
		.then ->
			rsync = spawn('rsync', rsyncArgs)
			deltaStream.pipe(rsync.stdin)

			utils.waitPidAsync(rsync)
		.then ->
			# rsync doesn't fsync by itself
			utils.waitPidAsync(spawn('sync'))
		.catch (e) ->
			if code in DELTA_OUT_OF_SYNC_CODES
				throw new OutOfSyncError('Incompatible image')
			else
				throw e
		.then ->
			deltaStream.emit('id', dstId)
	
	return deltaStream

from = 'busybox:musl'
to = 'busybox:glibc'

fs = require 'fs'

# Delta creation
exports.createDelta(from, to).pipe(fs.createWriteStream('test'))

# Delta application
# fs.createReadStream('test').pipe(exports.applyDelta(from)).once('id', (id) ->
# 	console.log('Created image', id)
# )
