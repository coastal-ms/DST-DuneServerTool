import copy
import importlib.util
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parents[1] / 'app/resources/solo-mods/dst-solo-live-map/Companion/vehicle_fuel.py'
spec = importlib.util.spec_from_file_location('solo_vehicle_fuel', PATH)
fuel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fuel)


class VehicleFuelTests(unittest.TestCase):
    def setUp(self):
        self.live = {'id': 'live', 'kind': 'vehicle', 'class': 'BlueprintGeneratedClass /Game/Buggy.Buggy_C',
                     'location': {'x': 100000, 'y': 200000, 'z': 1000}}
        self.saved = {'savedId': 'saved', 'class': '/Game/Buggy.Buggy_C', 'location': dict(self.live['location']),
                      'fuel': 150, 'fuelCapacity': 300, 'fuelSavedAt': 100}

    def test_unique_nearby_match_has_saved_percentage(self):
        fuel.enrich([self.live], [self.saved])
        self.assertEqual(self.live['fuel'] / self.live['fuelCapacity'], .5)
        self.assertEqual(self.live['fuelSavedAt'], 100)

    def test_ambiguous_saved_vehicles_are_not_assigned(self):
        fuel.enrich([self.live], [self.saved, copy.deepcopy(self.saved)])
        self.assertNotIn('fuel', self.live)

    def test_one_saved_vehicle_cannot_supply_two_live_vehicles(self):
        second = copy.deepcopy(self.live)
        fuel.enrich([self.live, second], [self.saved])
        self.assertNotIn('fuel', self.live)
        self.assertNotIn('fuel', second)

    def test_distant_or_other_type_cannot_supply_fuel(self):
        self.saved['location']['x'] += 30000
        fuel.enrich([self.live], [self.saved])
        self.assertNotIn('fuel', self.live)
        self.saved['location'] = dict(self.live['location'])
        self.saved['class'] = '/Game/Scout.Scout_C'
        fuel.enrich([self.live], [self.saved])
        self.assertNotIn('fuel', self.live)


if __name__ == '__main__':
    unittest.main()
