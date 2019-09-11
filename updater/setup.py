import sys

from setuptools import setup, find_packages

needs_pytest = {'pytest', 'test', 'ptr'}.intersection(sys.argv)
pytest_runner = ['pytest-runner'] if needs_pytest else []

setup(
    name="avonc-updater",
    packages=find_packages(),
    setup_requires=pytest_runner,
    entry_points={'console_scripts': ['update=updater.main:main']}
)
