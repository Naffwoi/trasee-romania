import unittest

from enrich_trail_photos_commons import (
    is_acceptable_commons_title,
    is_free_license,
    is_in_romania_bbox,
    is_placeholder_photo,
    match_curated_slug,
)


class EnrichTrailPhotosCommonsTest(unittest.TestCase):
    def test_romania_bbox_rejects_swiss_tamina_and_accepts_brasov(self) -> None:
        # Pfafers, Switzerland (~46.99N, 9.50E) must be rejected.
        self.assertFalse(is_in_romania_bbox(46.991, 9.501))
        # Canionul Tamina, Brasov (~45.548N, 25.643E) must be accepted.
        self.assertTrue(is_in_romania_bbox(45.548, 25.643))

    def test_license_and_title_filters(self) -> None:
        self.assertTrue(is_free_license("CC0"))
        self.assertTrue(is_free_license("CC BY-SA 4.0"))
        self.assertTrue(is_free_license("CC BY 3.0"))
        self.assertFalse(is_free_license("CC BY-NC 4.0"))
        self.assertFalse(is_free_license("Copyrighted"))

        self.assertTrue(is_acceptable_commons_title("File:RO BV Canionul Tamina.jpg"))
        self.assertFalse(is_acceptable_commons_title("File:Brasov_location_map.svg"))
        self.assertFalse(is_acceptable_commons_title("File:Romania_harta.png"))

    def test_placeholder_detection_and_curated_slug_matching(self) -> None:
        self.assertTrue(is_placeholder_photo(""))
        self.assertTrue(is_placeholder_photo("wanderer_route_placeholder_abc.svg"))
        self.assertFalse(is_placeholder_photo("cascada_tamina_xyz.jpg"))

        self.assertEqual(
            match_curated_slug("Timișu de Sus - Cascada Tamina - Stâna sub Piatra Mare", "DN1"),
            "cascada_tamina",
        )
        self.assertEqual(
            match_curated_slug("Predeal - Fetifoiu - La Șipote", "Predeal"),
            "predeal_clabucet",
        )
        self.assertEqual(
            match_curated_slug("Vf. Ciucaș din Pasul Bratocea"),
            "varful_ciucas",
        )


if __name__ == "__main__":
    unittest.main()
