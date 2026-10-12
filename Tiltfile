# Live rebuild of the service images against Rancher Desktop's Kubernetes.
#
#   tilt up            # from the infra checkout, siblings checked out next to it
#
# Each image is built by images/service/build.sh from the local checkout
# (SRC=../<repo>), so uncommitted changes are included. With the dockerd
# (moby) engine the cluster sees the built images directly; nothing is pushed.

allow_k8s_contexts('rancher-desktop')

registry = 'ghcr.io/winterchill-trading'

# (repo, binary): every image the dev profile runs.
services = [
    ('hl-sim', 'hl-sim'),
    ('binance-sim', 'binance-sim'),
    ('bybit-sim', 'bybit-sim'),
    ('market-recorder', 'market-recorder'),
    ('market-data', 'market-data'),
]

for repo, bin in services:
    src = '../' + repo
    custom_build(
        registry + '/' + repo,
        'SRC=%s TAG=$EXPECTED_REF images/service/build.sh %s %s' % (src, repo, bin)
        + (' --build-arg RUNTIME_PACKAGES=rclone' if repo == 'market-recorder' else ''),
        deps=[src + '/bin', src + '/lib', src + '/src', src + '/dune-project'],
        ignore=['**/_build*'],
        disable_push=True,
        skips_local_docker=False,
    )

k8s_yaml(helm(
    'charts/winterchill',
    name='winterchill',
    values=['charts/winterchill/values-dev.yaml'],
))

for repo, _ in services[:3]:
    port = {'hl-sim': 3000, 'binance-sim': 3300, 'bybit-sim': 3400}[repo]
    k8s_resource('winterchill-' + repo, port_forwards=port, labels=['sims'])

for venue in ['binance', 'bybit', 'hyperliquid']:
    k8s_resource(
        'winterchill-recorder-' + venue,
        resource_deps=['winterchill-hl-sim', 'winterchill-binance-sim', 'winterchill-bybit-sim'],
        labels=['recorders'],
    )
