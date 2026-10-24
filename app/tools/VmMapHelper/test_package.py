import unittest
from package import deployment

class PackageTests(unittest.TestCase):
    def test_single_private_collector_reuses_dst_authentication(self):
        result=deployment(dict(namespace='game',dbPod='game-db-dbdepl-sts-0'))
        role=next(x for x in result['items'] if x['kind']=='Role')
        self.assertEqual(role['rules'][1]['resourceNames'],['game-db-dbdepl-sts-0'])
        pod=result['items'][-1]['spec']['template']['spec']
        self.assertEqual([x['name'] for x in pod['containers']],['collector'])
        self.assertFalse(pod['automountServiceAccountToken'])
        history=next(v for v in pod['volumes'] if v['name']=='snapshots')
        self.assertEqual(history['hostPath']['path'],'/var/lib/dst-map-helper/snapshots')
        mount=next(v for v in pod['containers'][0]['volumeMounts'] if v['name']=='snapshots')
        self.assertEqual(mount['mountPath'],'/work/snapshots')
        self.assertFalse(mount['readOnly'])
        collector=pod['containers'][0]
        self.assertEqual(collector['resources']['limits']['memory'],'250M')
        env={x['name']:x['value'] for x in collector['env']}
        self.assertEqual(env['DST_ATLAS_PORT'],'18446')
        for name in ('readinessProbe','livenessProbe'):
            command=collector[name]['exec']['command'][-1]
            self.assertIn('socket.create_connection',command)
            self.assertNotIn('/state',command)

if __name__=='__main__':unittest.main()
